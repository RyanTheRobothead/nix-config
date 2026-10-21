# vulnscan-inventory -- record which images a host is running
#
#   vulnscan-inventory <host>              this host, via the Docker socket
#   vulnscan-inventory <host> <ssh-dest>   a remote host, over SSH
#
# Writes <state>/inventory/<host>.json: every running container with its image,
# the registry digest it was pinned by, its published ports and its exposure
# (public, tailnet or local, from exposure.json). For this host it also saves
# each new image with `docker save` into the spool, keyed by that digest, so the
# scanners read image files without the Docker socket or a registry pull.
#
# INVENTORY_CMD and the defaults (VULNSCAN_*_DEFAULT) are injected above this
# file by the NixOS module. Every default can be overridden by an env var.

: "${VULNSCAN_STATE_DEFAULT:=/var/lib/vulnscan}"
: "${VULNSCAN_SPOOL_DEFAULT:=/var/cache/vulnscan/images}"
: "${VULNSCAN_EXPOSURE_DEFAULT:=/etc/vulnscan/exposure.json}"
: "${VULNSCAN_GROUP_DEFAULT:=vulnscan}"

STATE="${VULNSCAN_STATE:-$VULNSCAN_STATE_DEFAULT}"
SPOOL="${VULNSCAN_SPOOL:-$VULNSCAN_SPOOL_DEFAULT}"
EXPOSURE="${VULNSCAN_EXPOSURE:-$VULNSCAN_EXPOSURE_DEFAULT}"
GROUP="${VULNSCAN_GROUP:-$VULNSCAN_GROUP_DEFAULT}"
SSH_KEY="${VULNSCAN_SSH_KEY:-}"

if [ $# -lt 1 ] || [ $# -gt 2 ]; then
  echo "usage: vulnscan-inventory <host> [<ssh-dest>]" >&2
  exit 2
fi
HOST="$1"
DEST="${2:-}"

umask 027

# The scanners read what the root unit writes, but never own it
share() {
  chmod 0640 "$@"
  if [ "$(id -u)" = 0 ]; then chgrp "$GROUP" "$@"; fi
}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# One JSON array per line: [name, image, imageId, networkMode, ports, service]
# for each container, then [imageId, repoDigests] for each image in use
if [ -n "$DEST" ]; then
  # The remote side's authorized_keys forces INVENTORY_CMD; nothing else runs
  ssh_opts=(-o BatchMode=yes -o StrictHostKeyChecking=yes -o IdentitiesOnly=yes)
  if [ -n "$SSH_KEY" ]; then ssh_opts+=(-i "$SSH_KEY"); fi
  ssh "${ssh_opts[@]}" "$DEST" inventory >"$tmp/raw"
else
  sh -c "$INVENTORY_CMD" >"$tmp/raw"
fi

jq -s --arg host "$HOST" --slurpfile exposure "$EXPOSURE" '
  # Repository part of an image reference: no tag or digest, Docker Hub
  # spelled the short way, so "docker.io/library/postgres:16" is "postgres"
  def repo:
    sub("@sha256:.*$"; "") | sub(":[^/:]*$"; "")
    | sub("^docker\\.io/"; "") | sub("^library/"; "");

  ($exposure[0][$host] // {internetFacing: false, public: []}) as $e
  | (map(select(length == 2) | {key: .[0], value: (.[1] // [])}) | from_entries)
    as $digests
  | [ .[] | select(length == 6)
      | . as [$name0, $image, $id, $net, $ports, $service]
      | ($name0 | ltrimstr("/")) as $name
      | ($digests[$id] // []) as $rd
      # The digest it was pinned by: the RepoDigest of the repo it was started
      # from, any RepoDigest, or the image ID for an image never pushed
      | (([$rd[] | select(repo == ($image | repo))] + $rd)[0] // $id
          | sub("^.*@"; "")) as $digest
      | [($ports // {})[] | (. // [])[] | .HostIp] as $binds
      | ($binds | any(. == "0.0.0.0" or . == "::" or . == "")) as $everywhere
      | ($e.public | index($name)) as $listed
      | {
          name: $name,
          service: $service,
          image: $image,
          imageId: $id,
          repoDigests: $rd,
          digest: $digest,
          networkMode: $net,
          ports: $ports,
          exposure: (
            if $listed != null or ($e.internetFacing and $everywhere) then "public"
            elif ($binds | length) == 0 and ($net | test("^(host|container:)") | not)
            then "local"
            else "tailnet"
            end),
          # Public only because it binds every interface: nobody decided that
          unlistedPublic: ($listed == null and $e.internetFacing and $everywhere)
        }
    ]
  | {host: $host, generated: (now | todate), containers: sort_by(.name)}
' "$tmp/raw" >"$tmp/inventory.json"

jq -r '.containers[] | select(.unlistedPublic) | .name' "$tmp/inventory.json" |
  while read -r name; do
    echo "warning: $HOST/$name publishes on every interface of an internet-facing host but isn't listed in exposure.nix" >&2
  done

# inventory/ is shared with the vulnscan user: mktemp never reuses a name
# someone else planted, and mv replaces the old file without following it
mkdir -p "$STATE/inventory"
new=$(mktemp "$STATE/inventory/.$HOST.XXXXXX")
cat "$tmp/inventory.json" >"$new"
share "$new"
mv -f "$new" "$STATE/inventory/$HOST.json"
echo "$HOST: $(jq '.containers | length' "$tmp/inventory.json") containers"

# Remote images are pulled by digest from their registry when scanned
[ -z "$DEST" ] || exit 0

mkdir -p "$SPOOL"
jq -r '.containers | unique_by(.digest)[] | "\(.digest) \(.imageId)"' \
  "$tmp/inventory.json" >"$tmp/images"

while read -r digest id; do
  f="$SPOOL/${digest#sha256:}.tar"
  [ -e "$f" ] && continue
  echo "saving $digest ($id)"
  docker save "$id" >"$f.part"
  share "$f.part"
  mv "$f.part" "$f"
done <"$tmp/images"

# Drop images nothing runs any more, and any save cut short
for f in "$SPOOL"/*.tar "$SPOOL"/*.part; do
  [ -e "$f" ] || continue
  digest="sha256:$(basename "$f" .tar)"
  case "$f" in
  *.part) ;;
  *) grep -q "^$digest " "$tmp/images" && continue ;;
  esac
  echo "removing $(basename "$f")"
  rm -f "$f"
done
