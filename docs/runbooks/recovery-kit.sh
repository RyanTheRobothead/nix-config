#!/usr/bin/env bash
# Build and copy the offline recovery kit (see recovery-kit.md). Run as your user, not root.
#
#   bash docs/runbooks/recovery-kit.sh build              # new kit, adds a fresh restic break-glass key
#   bash docs/runbooks/recovery-kit.sh build --from FILE  # regenerate, starting from an existing kit
#   bash docs/runbooks/recovery-kit.sh install MOUNTPOINT # copy the built kit to a USB stick and verify
#
# The plaintext only ever exists under $XDG_RUNTIME_DIR (tmpfs, mode 0700) and is shredded on exit.
# Nothing secret is printed; only paths and the ciphertext's sha256.
set -euo pipefail

REPO=$(cd "$(dirname "$0")/../.." && pwd)
OUT=${RECOVERY_KIT_OUT:-$HOME/recovery-kit}
VERIFY_ID=$HOME/.config/sops/age/yubikey-37817094.txt

die() { echo "error: $*" >&2; exit 1; }

# The three offline admin recipients from .sops.yaml; the server key is deliberately left out
recipients() {
  grep -oP '&admin_\S+\s+\Kage1\S+' "$REPO/.sops.yaml"
}

# Open a file in the editor with swap, undo, backup and shada files off, so no copy lands on disk
edit_secret() {
  case "$(basename "${EDITOR:-vi}")" in
    nvim|vim|vi)
      "${EDITOR:-vi}" -n -i NONE --cmd 'set noundofile nobackup nowritebackup' "$1" ;;
    *)
      echo "warning: \$EDITOR is not vim/nvim; make sure it writes no swap or backup files" >&2
      "${EDITOR}" "$1" ;;
  esac
}

build() {
  local from=""
  if [ "${1:-}" = "--from" ]; then from=${2:?--from needs a file}; fi

  [ "$(id -u)" -ne 0 ] || die "run as your user; the script calls sudo where it needs it"
  [ -r "$VERIFY_ID" ] || die "missing YubiKey identity stub $VERIFY_ID"
  command -v age >/dev/null && command -v age-plugin-yubikey >/dev/null \
    || die "age and age-plugin-yubikey must be on PATH"
  [ "$(recipients | wc -l)" -eq 3 ] || die "expected 3 admin recipients in .sops.yaml"

  local work
  work=$(mktemp -d -p "${XDG_RUNTIME_DIR:?XDG_RUNTIME_DIR unset}" recovery-kit.XXXXXX)
  chmod 700 "$work"
  # shellcheck disable=SC2064
  trap "find '$work' -type f -exec shred -u {} +; rm -rf '$work'" EXIT
  local plain=$work/recovery-kit.txt

  if [ -n "$from" ]; then
    echo "Decrypting $from to start from it (touch the YubiKey when it blinks)"
    age -d -i "$VERIFY_ID" -o "$plain" "$from"
  else
    echo "Adding a restic break-glass key to b2:ryan-the-robothead-aegis-backup"
    local pw=$work/restic-breakglass
    # 32 random bytes, base64: about 256 bits, typeable from paper if it ever comes to that
    head -c 32 /dev/urandom | base64 | tr -d '\n' > "$pw"
    sudo restic-backblaze key add --host recovery-kit --user admin --new-password-file "$pw"
    # The flag overrides the wrapper's own password file, so this proves the new key alone opens the repo
    sudo restic-backblaze --password-file "$pw" snapshots --latest 1 >/dev/null \
      || die "the new break-glass password did not open the repository"
    echo "Break-glass key works"
    # Substitute in the shell rather than with sed, so the password never appears in a process's argv
    local template
    template=$(<"$REPO/docs/runbooks/recovery-kit.template")
    printf '%s\n' "${template//@RESTIC_BREAKGLASS@/$(<"$pw")}" > "$plain"
  fi

  echo "Opening the kit in $EDITOR. Paste each value from Vaultwarden over its FILL-ME, then save and quit."
  edit_secret "$plain"
  if grep -q 'FILL-ME' "$plain"; then
    die "FILL-ME placeholders remain; nothing was written (re-run when you have every value)"
  fi
  sed -i "s|^Built: .*|Built: $(date -I)|" "$plain"

  mkdir -p "$OUT"
  local kit=$OUT/recovery-kit.age
  [ ! -e "$kit" ] || mv "$kit" "$OUT/recovery-kit.$(date +%Y%m%dT%H%M%S).age.old"
  recipients | age -e -R - -o "$kit" "$plain"

  echo "Verifying the kit decrypts with YubiKey 37817094 (touch it when it blinks)"
  local want got
  want=$(sha256sum < "$plain" | cut -d' ' -f1)
  got=$(age -d -i "$VERIFY_ID" "$kit" | sha256sum | cut -d' ' -f1)
  [ "$want" = "$got" ] || die "decrypted kit does not match what was encrypted"

  cp "$REPO/docs/runbooks/recovery-kit-README.txt" "$OUT/README.txt"
  (cd "$OUT" && sha256sum recovery-kit.age README.txt > SHA256SUMS)
  echo "Kit built and verified: $kit"
  echo "sha256: $(sha256sum < "$kit" | cut -d' ' -f1)"
  echo "Record that date and hash in docs/runbooks/recovery-kit.md, then run: install <stick mountpoint>"
}

install_kit() {
  local dest=${1:?install needs the stick mountpoint}
  mountpoint -q "$dest" || die "$dest is not a mountpoint"
  for f in recovery-kit.age README.txt SHA256SUMS; do
    [ -r "$OUT/$f" ] || die "missing $OUT/$f; run build first"
  done
  mkdir -p "$dest/recovery-kit"
  cp "$OUT/recovery-kit.age" "$OUT/README.txt" "$OUT/SHA256SUMS" "$dest/recovery-kit/"
  sync
  # Drop the page cache so the check reads the stick, not memory
  echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null
  (cd "$dest/recovery-kit" && sha256sum -c SHA256SUMS)
  echo "Copied to $dest/recovery-kit. Unmount before pulling the stick: udisksctl unmount -b <device>"
}

case "${1:-}" in
  build) shift; build "$@" ;;
  install) shift; install_kit "$@" ;;
  *) sed -n '2,9p' "$0"; exit 1 ;;
esac
