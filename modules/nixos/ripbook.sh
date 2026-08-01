# ripbook -- rip a multi-disc audiobook from CD into a single chaptered .m4b
#
# Defaults (RIPBOOK_*_DEFAULT) are injected above this file by the NixOS module.
# Every one of them can be overridden per-run by a flag or an env var.

: "${RIPBOOK_LIBRARY_DEFAULT:=}"
: "${RIPBOOK_WORK_DEFAULT:=/var/cache/ripbook}"
: "${RIPBOOK_DEVICE_DEFAULT:=/dev/cdrom}"
: "${RIPBOOK_BITRATE_DEFAULT:=64k}"
: "${RIPBOOK_CHANNELS_DEFAULT:=1}"
: "${RIPBOOK_CONTACT_DEFAULT:=ripbook}"

LIBRARY="${RIPBOOK_LIBRARY:-$RIPBOOK_LIBRARY_DEFAULT}"
WORKROOT="${RIPBOOK_WORK:-$RIPBOOK_WORK_DEFAULT}"
DEVICE="${RIPBOOK_DEVICE:-$RIPBOOK_DEVICE_DEFAULT}"
BITRATE="${RIPBOOK_BITRATE:-$RIPBOOK_BITRATE_DEFAULT}"
CHANNELS="${RIPBOOK_CHANNELS:-$RIPBOOK_CHANNELS_DEFAULT}"
USER_AGENT="ripbook/1.0 ( ${RIPBOOK_CONTACT_DEFAULT} )"

FAST=0
KEEP=0
LOOKUP=1
RESUME=""
ENCODE_ONLY=0
RETRIES=3
TOC_ATTEMPTS=5
DISC_TOTAL=""

umask 022

# ---------------------------------------------------------------- output ----

if [[ -t 1 ]]; then
  C_B=$'\e[1m'; C_DIM=$'\e[2m'; C_G=$'\e[32m'; C_Y=$'\e[33m'; C_R=$'\e[31m'; C_0=$'\e[0m'
else
  C_B=""; C_DIM=""; C_G=""; C_Y=""; C_R=""; C_0=""
fi

info() { printf '%s==>%s %s\n' "$C_B" "$C_0" "$*"; }
warn() { printf '%swarning:%s %s\n' "$C_Y" "$C_0" "$*" >&2; }
die()  { printf '%serror:%s %s\n' "$C_R" "$C_0" "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
ripbook -- rip a multi-disc audiobook to a single chaptered .m4b

Usage:
  ripbook [options]
  ripbook --resume <slug>
  ripbook --encode-only <slug>
  ripbook --list

Options:
  -l, --library DIR   Audiobookshelf library root
  -w, --work DIR      Scratch space for intermediate WAVs
  -d, --device DEV    Optical drive (default: /dev/cdrom)
  -n, --discs N       How many discs the book has. Skips the "another disc?"
                      prompt entirely: each disc ejects and the next is picked
                      up as soon as you load it. Omit to be asked after each.
  -b, --bitrate RATE  AAC bitrate for the final m4b (default: 64k)
      --stereo        Encode stereo instead of mono
      --fast          Disable cdparanoia error correction (faster, riskier)
      --retries N     Attempts per track before giving up (default: 3)
      --keep          Keep intermediate WAVs after a successful encode
      --no-lookup     Skip the MusicBrainz lookup, prompt for everything
      --resume SLUG   Continue an interrupted book
      --encode-only SLUG
                      Re-encode an already-ripped book without touching the drive
      --list          List in-progress books in the work directory
  -h, --help          Show this help

The finished book lands in, per the Audiobookshelf directory convention:
  <library>/<Author>/[<Series>/]["Vol N - "]["Year - "]<Title>[" {Narrator}"]/<Title>.m4b
EOF
}

# ------------------------------------------------------------ arg parsing ---

while [[ $# -gt 0 ]]; do
  case "$1" in
    -l|--library)     LIBRARY="${2:-}"; shift 2 ;;
    -w|--work)        WORKROOT="${2:-}"; shift 2 ;;
    -d|--device)      DEVICE="${2:-}"; shift 2 ;;
    -b|--bitrate)     BITRATE="${2:-}"; shift 2 ;;
    --stereo)         CHANNELS=2; shift ;;
    --fast)           FAST=1; shift ;;
    --retries)        RETRIES="${2:-3}"; shift 2 ;;
    -n|--discs)       DISC_TOTAL="${2:-}"; shift 2 ;;
    --keep)           KEEP=1; shift ;;
    --no-lookup)      LOOKUP=0; shift ;;
    --resume)         RESUME="${2:-}"; shift 2 ;;
    --encode-only)    RESUME="${2:-}"; ENCODE_ONLY=1; shift 2 ;;
    --list)
      if [[ -d "$WORKROOT" ]]; then
        found=0
        for d in "$WORKROOT"/*/; do
          [[ -f "$d/state.json" ]] || continue
          found=1
          jq -r '
            (if (.disc_total // "") == "" then "\(.discs_done) disc(s)"
             else "\(.discs_done)/\(.disc_total) discs" end) as $progress
            | "\(.slug)\t\($progress)\t\(.author) - \(.title)"
          ' "$d/state.json"
        done
        [[ $found -eq 1 ]] || echo "No books in progress."
      else
        echo "No books in progress."
      fi
      exit 0 ;;
    -h|--help)        usage; exit 0 ;;
    *)                die "unknown option: $1 (try --help)" ;;
  esac
done

[[ -n "$LIBRARY" ]] || die "no library path set; pass --library or set services.audiobookRipper.libraryPath"

if [[ -n "$DISC_TOTAL" ]]; then
  if ! [[ "$DISC_TOTAL" =~ ^[0-9]+$ ]] || (( DISC_TOTAL == 0 )); then
    die "--discs takes a whole number of discs, got '$DISC_TOTAL'"
  fi
fi

# --------------------------------------------------------------- helpers ----

# Strip characters that have no business in a path component.
sanitize() {
  local s="$1"
  s="${s//\//-}"
  s="$(printf '%s' "$s" | tr -d '\000-\037' | tr -s ' ')"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  s="${s%.}"
  printf '%s' "$s"
}

is_disc_count() { [[ "$1" =~ ^[0-9]+$ ]] && (( $1 > 0 )); }

slugify() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' \
    | sed -e 's/[^a-z0-9]\+/-/g' -e 's/^-\+//' -e 's/-\+$//' | cut -c1-80
}

# Prompt with an editable default when we have a terminal.
ask() {
  local prompt="$1" default="${2:-}" reply=""
  if [[ -t 0 && -n "$default" ]]; then
    read -r -e -i "$default" -p "  $prompt: " reply || true
  else
    read -r -p "  $prompt${default:+ [$default]}: " reply || true
    [[ -n "$reply" ]] || reply="$default"
  fi
  sanitize "$reply"
}

confirm() {
  local prompt="$1" reply=""
  # A failed read means stdin closed; treat that as "no" so we never spin forever.
  if ! read -r -p "  $prompt [Y/n] " reply; then
    echo
    return 1
  fi
  [[ ! "$reply" =~ ^[Nn] ]]
}

# ffmetadata requires =, ;, #, \ and newlines to be backslash-escaped.
ffmeta_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/=/\\=/g' -e 's/;/\\;/g' -e 's/#/\\#/g'
}

# --------------------------------------------------------------- the disc ---

TOC_ERROR=""

# The device node vanishing means the drive fell off the bus -- a USB drive
# browning out under load will do this -- which is worth saying out loud rather
# than looping forever waiting for a disc that can never appear.
require_device() {
  if [[ ! -e "$DEVICE" ]]; then
    die "$DEVICE does not exist -- is the drive connected and powered? (check: journalctl -k | tail)"
  fi
}

# Emits "tracknum length_sectors begin_sector" per audio track.
# Returns nonzero if the drive could not be read at all; leaves the drive's own
# complaint in TOC_ERROR. An empty TOC (data disc, no disc) is *not* an error
# here -- callers distinguish that by testing for empty output.
read_toc() {
  local raw
  if ! raw="$(cdparanoia -d "$DEVICE" -Q 2>&1)"; then
    TOC_ERROR="$raw"
    return 1
  fi
  printf '%s\n' "$raw" \
    | { grep -E '^[[:space:]]*[0-9]+\.' || true; } \
    | awk '{ n = $1; sub(/\./, "", n); print n, $2, $4 }'
}

disc_present() { read_toc 2>/dev/null | grep -q .; }

# Is a parsed TOC self-consistent? Every track must have a real length, and
# tracks must start in ascending order without overlapping each other. A drive
# handing back a merged or truncated TOC violates this immediately.
toc_sane() {
  awk '
    BEGIN { ok = 1; prev_begin = -1; prev_end = -1 }
    {
      if ($2 <= 0)          { ok = 0 }
      if ($3 <= prev_begin) { ok = 0 }
      if ($3 < prev_end)    { ok = 0 }
      prev_begin = $3
      prev_end   = $3 + $2
    }
    END { if (NR == 0) ok = 0; exit (ok ? 0 : 1) }
  ' "$1"
}

# Read the TOC and only believe it once two independent reads agree on a
# self-consistent answer. This drive intermittently reports merged tracks
# (several tracks collapsed into one, others zero-length), and every byte we
# rip afterwards is derived from this table -- a single bad read silently
# corrupts the whole disc.
read_toc_verified() {
  local dest="$1" attempt=0
  while (( attempt < TOC_ATTEMPTS )); do
    attempt=$(( attempt + 1 ))

    if ! read_toc >"$dest.a"; then
      rm -f "$dest.a"
      return 1
    fi
    # An empty TOC is a real answer (data disc / no disc), not a bad read.
    if [[ ! -s "$dest.a" ]]; then
      mv "$dest.a" "$dest"
      return 0
    fi

    if toc_sane "$dest.a" && read_toc >"$dest.b" 2>/dev/null && cmp -s "$dest.a" "$dest.b"; then
      mv "$dest.a" "$dest"
      rm -f "$dest.b"
      return 0
    fi

    rm -f "$dest.a" "$dest.b"
    if (( attempt < TOC_ATTEMPTS )); then
      warn "drive returned an inconsistent table of contents; re-reading it"
      sleep 2
    fi
  done
  return 1
}

# Wait until a disc is loaded. When prev_toc names the previous disc's TOC we
# also refuse to accept that same disc again: with disc-count mode there is no
# "next disc?" prompt to catch a tray closed without swapping, and re-ripping
# disc N as disc N+1 would silently duplicate a chunk of the book.
#
# Both sides of that comparison must be stable TOCs. prev_toc was written by
# read_toc_verified, and the disc in the drive is read the same way -- comparing
# a single raw read here would let one bad read of the *same* disc look like a
# different one, defeating the guard precisely when the drive is misbehaving.
wait_for_disc() {
  local n="$1" prev_toc="${2:-}" waited=0 nagged=0 label probe
  probe="$WORKDIR/.probe-toc"

  label="disc $n"
  if [[ -n "$DISC_TOTAL" ]]; then label="disc $n of $DISC_TOTAL"; fi

  while true; do
    if disc_present; then
      # If no stable TOC can be had, stop waiting and let rip_disc read it
      # again and fail with a proper diagnostic rather than stalling here.
      if [[ -n "$prev_toc" && -s "$prev_toc" ]] \
        && read_toc_verified "$probe" && [[ -s "$probe" ]] \
        && cmp -s "$probe" "$prev_toc"; then
        if (( nagged == 0 )); then
          printf '\r%*s\r' 72 ''
          printf '  %sthat is the disc just ripped -- swap in %s%s\n' "$C_Y" "$label" "$C_0"
          nagged=1
        fi
      else
        break
      fi
    elif (( waited == 0 )); then
      printf '  %sInsert %s and close the tray...%s' "$C_DIM" "$label" "$C_0"
    fi
    waited=1
    sleep 2
    require_device
  done

  rm -f "$probe" "$probe.a" "$probe.b"
  if (( waited == 1 )); then
    sleep 1   # let the drive settle after it spins up
  fi
  printf '\r%*s\r' 72 ''
  return 0
}

# MusicBrainz disc ID: SHA-1 over the TOC, base64 with a URL-safe alphabet.
compute_discid() {
  local toc_file="$1"
  python3 - "$toc_file" <<'PY'
import base64, hashlib, sys

tracks = {}
with open(sys.argv[1]) as fh:
    for line in fh:
        n, length, begin = line.split()
        tracks[int(n)] = (int(length), int(begin))

first, last = min(tracks), max(tracks)
# cdparanoia reports LSNs; MusicBrainz wants LBAs, which include the 150-sector pregap.
offsets = [tracks[i][1] + 150 for i in range(first, last + 1)]
leadout = tracks[last][1] + tracks[last][0] + 150

payload = "%02X%02X" % (first, last)
for value in [leadout] + offsets + [0] * (99 - len(offsets)):
    payload += "%08X" % value

digest = base64.b64encode(hashlib.sha1(payload.encode()).digest()).decode()
print(digest.replace("+", ".").replace("/", "_").replace("=", "-"))
print("%d+%d+%d+%s" % (first, last, leadout, "+".join(str(o) for o in offsets)))
PY
}

# Ask MusicBrainz about this disc. Exact disc-ID match first; the TOC endpoint is
# a fuzzy fallback, so anything it returns is a suggestion, never gospel.
musicbrainz_lookup() {
  local discid="$1" toc="$2" json="" base="https://musicbrainz.org/ws/2"

  json="$(curl -sf --max-time 20 -A "$USER_AGENT" \
    "$base/discid/$discid?fmt=json&inc=artist-credits+recordings" 2>/dev/null || true)"
  if [[ -n "$json" ]] && jq -e '.releases[0]' <<<"$json" >/dev/null 2>&1; then
    jq -c --arg exact true '{exact: true, releases: .releases}' <<<"$json"
    return 0
  fi

  sleep 1   # MusicBrainz asks for no more than one request per second
  json="$(curl -sf --max-time 20 -A "$USER_AGENT" \
    "$base/discid/-?toc=$toc&fmt=json&inc=artist-credits+recordings" 2>/dev/null || true)"
  if [[ -n "$json" ]] && jq -e '.releases[0]' <<<"$json" >/dev/null 2>&1; then
    jq -c '{exact: false, releases: .releases}' <<<"$json"
    return 0
  fi

  return 1
}

# ------------------------------------------------------------------ state ---

state_get() { jq -r --arg k "$1" '.[$k] // ""' "$STATE"; }

state_set() {
  local tmp="$STATE.tmp"
  jq --arg k "$1" --arg v "$2" '.[$k] = $v' "$STATE" >"$tmp" && mv "$tmp" "$STATE"
}

state_set_num() {
  local tmp="$STATE.tmp"
  jq --arg k "$1" --argjson v "$2" '.[$k] = $v' "$STATE" >"$tmp" && mv "$tmp" "$STATE"
}

# --------------------------------------------------------------- metadata ---

collect_metadata() {
  local sug_title="" sug_author=""

  if [[ $LOOKUP -eq 1 ]]; then
    info "Reading disc table of contents"
    if ! read_toc_verified "$WORKROOT/.toc.tmp"; then
      if [[ -n "$TOC_ERROR" ]]; then
        die "cannot read $DEVICE: $TOC_ERROR"
      fi
      die "drive could not produce a consistent table of contents after $TOC_ATTEMPTS tries -- try cleaning the disc"
    fi
    [[ -s "$WORKROOT/.toc.tmp" ]] || die "no audio tracks found on the disc in $DEVICE"

    local discid toc mb
    { read -r discid; read -r toc; } < <(compute_discid "$WORKROOT/.toc.tmp")
    printf '  %sdisc id: %s%s\n' "$C_DIM" "$discid" "$C_0"

    if mb="$(musicbrainz_lookup "$discid" "$toc")"; then
      sug_title="$(jq -r '.releases[0].title // ""' <<<"$mb")"
      sug_author="$(jq -r '.releases[0]."artist-credit"[0].name // ""' <<<"$mb")"
      if [[ "$(jq -r '.exact' <<<"$mb")" == "true" ]]; then
        printf '  %sMusicBrainz (exact match):%s %s - %s\n' "$C_G" "$C_0" "$sug_author" "$sug_title"
      else
        printf '  %sMusicBrainz (fuzzy, verify!):%s %s - %s\n' "$C_Y" "$C_0" "$sug_author" "$sug_title"
      fi
    else
      printf '  %sno MusicBrainz match -- expected for most audiobooks%s\n' "$C_DIM" "$C_0"
    fi
    rm -f "$WORKROOT/.toc.tmp"
  fi

  echo
  info "Book details (blank = skip)"
  AUTHOR="$(ask 'Author' "$sug_author")"
  [[ -n "$AUTHOR" ]] || die "an author is required -- Audiobookshelf groups by author folder"
  TITLE="$(ask 'Title' "$sug_title")"
  [[ -n "$TITLE" ]] || die "a title is required"
  SERIES="$(ask 'Series' '')"
  VOLUME=""
  if [[ -n "$SERIES" ]]; then
    VOLUME="$(ask 'Volume number' '')"
  fi
  YEAR="$(ask 'Publish year' '')"
  NARRATOR="$(ask 'Narrator' '')"

  # Knowing the disc count up front lets the rip run unattended: eject, swap,
  # and it picks the next disc up on its own instead of asking each time.
  local answer
  while [[ -z "$DISC_TOTAL" ]]; do
    answer="$(ask 'Number of discs (blank = ask after each)' '')"
    if [[ -z "$answer" ]]; then
      break                       # blank: fall back to prompting per disc
    fi
    if is_disc_count "$answer"; then
      DISC_TOTAL="$answer"
      break
    fi
    warn "that is not a disc count; enter a whole number, or leave it blank"
  done
}

build_bookdir() {
  local leaf=""
  if [[ -n "$VOLUME" ]]; then leaf+="Vol $VOLUME - "; fi
  if [[ -n "$YEAR" ]];   then leaf+="$YEAR - "; fi
  leaf+="$TITLE"
  if [[ -n "$NARRATOR" ]]; then leaf+=" {$NARRATOR}"; fi

  BOOKDIR="$LIBRARY/$AUTHOR"
  if [[ -n "$SERIES" ]]; then BOOKDIR="$BOOKDIR/$SERIES"; fi
  BOOKDIR="$BOOKDIR/$leaf"
}

# ----------------------------------------------------------------- ripping --

rip_disc() {
  local disc="$1"
  local toc_file
  toc_file="$WORKDIR/toc-disc$(printf '%02d' "$disc").txt"

  if ! read_toc_verified "$toc_file"; then
    if [[ -n "$TOC_ERROR" ]]; then
      die "cannot read $DEVICE: $TOC_ERROR"
    fi
    die "drive could not produce a consistent table of contents for disc $disc after $TOC_ATTEMPTS tries -- clean the disc and retry with: ripbook --resume $SLUG"
  fi
  [[ -s "$toc_file" ]] || die "no audio tracks on disc $disc (is it a data disc?)"

  local total
  total="$(wc -l <"$toc_file")"
  info "Disc $disc: $total tracks"

  local n sectors begin secs log out prev
  while read -r n sectors begin; do
    : "$begin"
    out="$WORKDIR/$(printf 'disc%02d-track%03d.wav' "$disc" "$n")"

    # A track left over from an earlier attempt is only worth keeping if it is
    # the length the disc says it should be -- re-check rather than assume.
    if [[ -s "$out" ]]; then
      prev="$(stat -c %s "$out")"
      if (( prev <= sectors * 2352 + 44 + 9408 && prev >= sectors * 2352 + 44 - 9408 )); then
        printf '  track %2d/%-2d  %salready ripped%s\n' "$n" "$total" "$C_DIM" "$C_0"
        continue
      fi
      warn "track $n was previously ripped at the wrong length; re-ripping it"
      rm -f "$out"
    fi

    secs=$(( sectors / 75 ))
    printf '  track %2d/%-2d  %d:%02d  ' "$n" "$total" $(( secs / 60 )) $(( secs % 60 ))

    log="$WORKDIR/.cdparanoia.log"
    local -a args=(-d "$DEVICE" -w)
    if [[ $FAST -eq 1 ]]; then args+=(-Z); fi

    # Each track is a fresh open/read/close of the drive. Cheap USB drives
    # intermittently hand back a garbage TOC on one of those opens. Sometimes
    # that surfaces as "Invalid track number" on a track that reads fine
    # moments later; sometimes cdparanoia cheerfully rips straight past the
    # track boundary and reports success. The second kind is the dangerous one,
    # so verify the length rather than trusting the exit status: CD audio is
    # exactly 2352 bytes per sector, and cdparanoia writes a 44-byte WAV header,
    # which makes the correct size known in advance to the byte.
    local attempt=0 expected actual reason
    expected=$(( sectors * 2352 + 44 ))
    while true; do
      attempt=$(( attempt + 1 ))
      reason=""
      if ! cdparanoia "${args[@]}" "$n" "$out.part" </dev/null >"$log" 2>&1; then
        reason="cdparanoia reported an error"
      elif [[ ! -s "$out.part" ]]; then
        reason="produced no audio"
      else
        actual="$(stat -c %s "$out.part")"
        # Tolerate a few sectors of slop; anything more means a bad read.
        if (( actual > expected + 9408 || actual < expected - 9408 )); then
          reason="wrong length: got $(( actual / 176400 ))s, disc says $(( expected / 176400 ))s"
        fi
      fi

      if [[ -z "$reason" ]]; then
        break
      fi
      rm -f "$out.part"

      if [[ ! -e "$DEVICE" ]]; then
        printf '%sFAILED%s\n' "$C_R" "$C_0"
        die "the drive fell off the bus mid-rip ($DEVICE is gone). Reconnect it, then: ripbook --resume $SLUG"
      fi
      if [[ $attempt -ge $RETRIES ]]; then
        printf '%sFAILED%s%s\n' "$C_R" "$C_0" " ($reason)"
        tail -n 20 "$log" >&2
        die "could not read track $n of disc $disc after $attempt attempts. Retry with: ripbook --resume $SLUG"
      fi
      printf '%sretry %d (%s)%s ' "$C_Y" "$attempt" "$reason" "$C_0"
      sleep 3
    done

    mv "$out.part" "$out"
    printf '%sok%s\n' "$C_G" "$C_0"
  done <"$toc_file"

  rm -f "$WORKDIR/.cdparanoia.log"
}

# ---------------------------------------------------------------- encoding --

encode_book() {
  local concat="$WORKDIR/concat.txt" meta="$WORKDIR/chapters.ffmeta"
  local -a wavs=()
  mapfile -t wavs < <(find "$WORKDIR" -maxdepth 1 -name 'disc*-track*.wav' -print | sort)
  [[ ${#wavs[@]} -gt 0 ]] || die "no ripped tracks found in $WORKDIR"

  info "Encoding ${#wavs[@]} tracks to m4b (${BITRATE}, $([[ $CHANNELS -eq 1 ]] && echo mono || echo stereo))"

  : >"$concat"
  {
    echo ';FFMETADATA1'
    echo "title=$(ffmeta_escape "$TITLE")"
    echo "album=$(ffmeta_escape "$TITLE")"
    echo "artist=$(ffmeta_escape "$AUTHOR")"
    echo "album_artist=$(ffmeta_escape "$AUTHOR")"
    echo "genre=Audiobook"
    echo "media_type=2"
    if [[ -n "$NARRATOR" ]]; then echo "composer=$(ffmeta_escape "$NARRATOR")"; fi
    if [[ -n "$YEAR" ]];     then echo "date=$(ffmeta_escape "$YEAR")"; fi
    if [[ -n "$SERIES" ]]; then
      echo "show=$(ffmeta_escape "$SERIES")"
      if [[ -n "$VOLUME" ]]; then echo "episode_id=$(ffmeta_escape "$VOLUME")"; fi
    fi
    true
  } >"$meta"

  local start=0 idx=0 dur_ms end wav escaped
  for wav in "${wavs[@]}"; do
    escaped="${wav//\'/\'\\\'\'}"
    printf "file '%s'\n" "$escaped" >>"$concat"

    dur_ms="$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$wav" \
      | awk '{ printf "%.0f", $1 * 1000 }')"
    [[ -n "$dur_ms" && "$dur_ms" != "0" ]] || die "could not read duration of $wav"

    idx=$(( idx + 1 ))
    end=$(( start + dur_ms ))
    {
      echo '[CHAPTER]'
      echo 'TIMEBASE=1/1000'
      echo "START=$start"
      echo "END=$end"
      echo "title=Chapter $idx"
    } >>"$meta"
    start="$end"
  done

  printf '  %stotal runtime: %d:%02d:%02d%s\n' "$C_DIM" \
    $(( start / 3600000 )) $(( start / 60000 % 60 )) $(( start / 1000 % 60 )) "$C_0"

  local out="$WORKDIR/output.m4b"
  rm -f "$out"
  ffmpeg -nostdin -hide_banner -loglevel error -stats \
    -f concat -safe 0 -i "$concat" \
    -i "$meta" \
    -map 0:a -map_metadata 1 -map_chapters 1 \
    -c:a aac -b:a "$BITRATE" -ac "$CHANNELS" \
    -movflags +faststart \
    -f mp4 "$out" \
    || die "ffmpeg failed to encode the book"

  [[ -s "$out" ]] || die "ffmpeg produced an empty file"
  ENCODED="$out"
}

# -------------------------------------------------------------------- main --

mkdir -p "$WORKROOT"

if [[ $ENCODE_ONLY -eq 0 ]]; then
  require_device
fi

if [[ -n "$RESUME" ]]; then
  WORKDIR="$WORKROOT/$RESUME"
  STATE="$WORKDIR/state.json"
  [[ -f "$STATE" ]] || die "no book in progress with slug '$RESUME' (try --list)"
  AUTHOR="$(state_get author)"
  TITLE="$(state_get title)"
  SERIES="$(state_get series)"
  VOLUME="$(state_get volume)"
  YEAR="$(state_get year)"
  NARRATOR="$(state_get narrator)"
  BOOKDIR="$(state_get bookdir)"
  DISCS_DONE="$(jq -r '.discs_done // 0' "$STATE")"
  # An explicit --discs on resume wins, and is remembered for later resumes.
  if [[ -n "$DISC_TOTAL" ]]; then
    state_set disc_total "$DISC_TOTAL"
  else
    DISC_TOTAL="$(state_get disc_total)"
  fi
  if [[ -n "$DISC_TOTAL" ]]; then
    info "Resuming: $AUTHOR - $TITLE ($DISCS_DONE of $DISC_TOTAL discs ripped)"
  else
    info "Resuming: $AUTHOR - $TITLE ($DISCS_DONE disc(s) already ripped)"
  fi
else
  collect_metadata
  build_bookdir
  SLUG="$(slugify "$AUTHOR-$TITLE")"
  WORKDIR="$WORKROOT/$SLUG"
  STATE="$WORKDIR/state.json"

  echo
  info "Will write to:"
  printf '  %s%s/%s.m4b%s\n' "$C_B" "$BOOKDIR" "$TITLE" "$C_0"
  confirm "Look right?" || die "aborted"

  if [[ -f "$STATE" ]]; then
    warn "a book with slug '$SLUG' is already in progress; resuming it"
    DISCS_DONE="$(jq -r '.discs_done // 0' "$STATE")"
  else
    mkdir -p "$WORKDIR"
    jq -n \
      --arg slug "$SLUG" --arg author "$AUTHOR" --arg title "$TITLE" \
      --arg series "$SERIES" --arg volume "$VOLUME" --arg year "$YEAR" \
      --arg narrator "$NARRATOR" --arg bookdir "$BOOKDIR" \
      --arg disc_total "$DISC_TOTAL" \
      '{slug: $slug, author: $author, title: $title, series: $series,
        volume: $volume, year: $year, narrator: $narrator, bookdir: $bookdir,
        disc_total: $disc_total, discs_done: 0}' >"$STATE"
    DISCS_DONE=0
  fi
fi

trap 'echo; warn "interrupted -- resume with: ripbook --resume ${SLUG:-$RESUME}"; exit 130' INT

SLUG="${SLUG:-$RESUME}"

if [[ $ENCODE_ONLY -eq 0 ]]; then
  while true; do
    disc=$(( DISCS_DONE + 1 ))
    echo

    # Once a disc has been ripped, hand its TOC to the next wait so the same
    # disc going back in is spotted rather than ripped twice.
    prev_toc=""
    if (( disc > 1 )); then
      prev_toc="$WORKDIR/toc-disc$(printf '%02d' $(( disc - 1 ))).txt"
    fi

    wait_for_disc "$disc" "$prev_toc"
    rip_disc "$disc"
    DISCS_DONE="$disc"
    state_set_num discs_done "$DISCS_DONE"

    eject "$DEVICE" >/dev/null 2>&1 || warn "could not eject $DEVICE"

    if [[ -n "$DISC_TOTAL" ]]; then
      # Disc count known: no prompting, just feed the next one in.
      if (( DISCS_DONE >= DISC_TOTAL )); then
        info "All $DISC_TOTAL discs ripped"
        break
      fi
      info "Ripped $DISCS_DONE of $DISC_TOTAL discs"
    else
      echo
      if ! confirm "Ripped $DISCS_DONE disc(s). Another disc?"; then
        break
      fi
    fi
  done
fi

echo
encode_book

mkdir -p "$BOOKDIR"
FINAL="$BOOKDIR/$(sanitize "$TITLE").m4b"
if [[ -e "$FINAL" ]]; then
  warn "$FINAL already exists"
  confirm "Overwrite it?" || die "aborted; encoded file left at $ENCODED"
fi
mv "$ENCODED" "$FINAL"
chmod 0644 "$FINAL"

echo
info "Done: $C_B$FINAL$C_0"
printf '  %s%s%s\n' "$C_DIM" "$(du -h "$FINAL" | cut -f1) on disk" "$C_0"

if [[ $KEEP -eq 1 ]]; then
  info "Intermediate WAVs kept in $WORKDIR"
else
  rm -rf "$WORKDIR"
fi

info "Trigger a library scan in Audiobookshelf to pick it up."
