#!/usr/bin/env bash
# Install a Linode host from scratch through the Linode API: no Cloud Manager.
#
#   just provision <host> [--create] [--yes]
#
# By default, rebuilds the existing Linode labelled as in hosts/<host>/linode.json,
# after showing it and asking for its label. Its ID and addresses stay, so DNS
# and Headscale's DERP addresses stay right. --create makes a new Linode
# instead, for when the old one is gone: it refuses if the label is taken, and
# prints the new addresses for dns/dnsconfig.js and modules/infra/headscale.nix.
# --yes skips the confirmation.
#
# Either way: Debian from the image (a bare filesystem, so it only boots in
# Linode's GRUB 2 mode), just install --no-reboot (nixos-anywhere), shut down,
# switch the config profile to Direct Disk with the boot helpers off, boot,
# and wait until the new system answers. Run it from a desktop session on
# Aegis: the API token (secrets/linode.yaml) and the host key need a YubiKey.
set -euo pipefail

usage() {
  sed -n '2,/^set -/p' "$0" | sed '$d; s/^# \{0,1\}//' >&2
  exit 2
}
die() {
  echo "provision: $*" >&2
  exit 1
}

host=${1:-}
[ -n "$host" ] || usage
shift
create=0
yes=0
for arg; do
  case $arg in
  --create) create=1 ;;
  --yes) yes=1 ;;
  *) usage ;;
  esac
done

spec=hosts/$host/linode.json
[ -f "$spec" ] || die "no $spec"
field() { jq -er ".$1" "$spec"; }
label=$(field label)
region=$(field region)
type=$(field type)
image=$(field image)
# How to tell the new system is up: "tailnet" (SSH is mesh-only) or "ssh"
ready=$(field ready)

LINODE_CLI_TOKEN=$(sops decrypt --extract '["linode_token"]' secrets/linode.yaml)
export LINODE_CLI_TOKEN
lcli() { linode-cli --json --no-defaults --suppress-warnings "$@"; }

# Before touching anything: the token works and both kernels exist
for k in linode/grub2 linode/direct-disk; do
  lcli kernels view "$k" >/dev/null || die "the API has no kernel $k (or the token is refused)"
done

# Reachable only until nixos-anywhere replaces Debian, so never printed or kept
root_pass=$(head -c 48 /dev/urandom | base64 | tr -d '/+=\n')
pubkey=$(cat ~/.ssh/id_ed25519.pub)

# Throwaway SSH options: a rebuilt Linode keeps its address but not its key
ssh_new=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o BatchMode=yes)

wait_status() {
  local s=""
  for _ in $(seq 120); do
    s=$(lcli linodes view "$1" | jq -r '.[0].status')
    [ "$s" = "$2" ] && return
    sleep 5
  done
  die "timed out waiting for $2 (last status: $s)"
}

# Until the Debian image answers as root. Status alone can't tell: right
# after a rebuild call the Linode can still report the old system running.
wait_debian() {
  for _ in $(seq 120); do
    if ssh "${ssh_new[@]}" "root@$1" 'grep -qx ID=debian /etc/os-release' 2>/dev/null; then
      return
    fi
    sleep 5
  done
  die "Debian never answered on root@$1"
}

found=$(lcli linodes list --label "$label" | jq --arg l "$label" '[.[] | select(.label == $l)]')
n=$(jq length <<<"$found")

if [ "$create" = 1 ]; then
  [ "$n" = 0 ] || die "a Linode labelled $label exists ($(jq -r '.[0].id' <<<"$found")); rebuild it instead, or delete it first"
  echo "Creating $label: $type in $region from $image"
  id=$(lcli linodes create --label "$label" --region "$region" --type "$type" \
    --image "$image" --root_pass "$root_pass" --authorized_keys "$pubkey" \
    --swap_size 0 --booted true | jq -er '.[0].id')
else
  [ "$n" = 1 ] || die "expected one Linode labelled $label, found $n (--create makes one)"
  id=$(jq -er '.[0].id' <<<"$found")
  jq -r '.[0] | "Linode \(.id): \(.label), \(.type) in \(.region), \(.status)\n  \(.ipv4 | join(" ")) \(.ipv6)"' <<<"$found"
  if [ "$yes" != 1 ]; then
    read -rp "This wipes it and reinstalls $host. Type its label to go on: " answer
    [ "$answer" = "$label" ] || die "not confirmed"
  fi
  echo "Rebuilding $label from $image"
  lcli linodes rebuild "$id" --image "$image" --root_pass "$root_pass" \
    --authorized_keys "$pubkey" --booted true >/dev/null
fi

view=$(lcli linodes view "$id")
ipv4=$(jq -er '.[0].ipv4[0]' <<<"$view")
ipv6=$(jq -er '.[0].ipv6 | split("/")[0]' <<<"$view")
echo "Waiting for Debian on $ipv4"
wait_debian "$ipv4"

configs=$(lcli linodes configs-list "$id")
[ "$(jq length <<<"$configs")" = 1 ] || die "expected one config profile on $id"
config=$(jq -er '.[0].id' <<<"$configs")
kernel=$(jq -r '.[0].kernel' <<<"$configs")
# The stock image needs Linode's GRUB until disko writes NixOS's own
[ "$kernel" = linode/grub2 ] || die "config $config boots $kernel, not linode/grub2; Debian's bare filesystem needs GRUB 2"

just install "$host" "$ipv4" --no-reboot

echo "Switching $label to Direct Disk"
lcli linodes shutdown "$id" >/dev/null
wait_status "$id" offline
# Every helper off: NixOS declares its own network and filesystems
lcli linodes config-update "$id" "$config" --kernel linode/direct-disk \
  --root_device /dev/sda --helpers.distro false --helpers.modules_dep false \
  --helpers.network false --helpers.devtmpfs_automount false \
  --helpers.updatedb_disabled true >/dev/null
booted=$(date +%s)
lcli linodes boot "$id" --config_id "$config" >/dev/null
wait_status "$id" running

# Up means booted since the boot call: an uptime shorter than that. Runs on
# the host, so its $(...) expands there.
# shellcheck disable=SC2016
fresh='[ "$(cut -d. -f1 /proc/uptime)" -lt '
echo "Waiting for NixOS ($ready)"
up=0
# shellcheck disable=SC2029 # $fresh and $since are meant to expand here
for _ in $(seq 120); do
  since=$(($(date +%s) - booted))
  case $ready in
  ssh)
    target="root@$ipv4"
    if ssh "${ssh_new[@]}" "$target" "$fresh$since ] && grep -qx ID=nixos /etc/os-release" 2>/dev/null; then
      up=1
      break
    fi
    ;;
  tailnet)
    # A node created after the boot call: the old one can still look online,
    # and the new one may register as <host>-1 until the old one is removed
    node=$(tailscale status --json | jq -r --arg h "$host" --argjson t "$booted" '
      [.Peer[] | select(.HostName == $h and .Online
        and (.Created | sub("\\.[0-9]+"; "") | fromdateiso8601) >= $t)][0]
      | select(.) | "\(.TailscaleIPs[0]) \(.DNSName)"')
    if [ -n "$node" ]; then
      target=${node%% *}
      # The host key is the one in sops, but this tailnet address may be new
      if ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 -o BatchMode=yes \
        "$target" "$fresh$since ]" 2>/dev/null; then
        up=1
        break
      fi
    fi
    ;;
  *) die "unknown ready check: $ready" ;;
  esac
  sleep 5
done
[ "$up" = 1 ] || die "$host didn't come up after booting; watch it on Lish"

echo "$host is up: Linode $id, $ipv4, $ipv6"
if [ "$ready" = tailnet ] && [[ ${node#* } != "$host".* ]]; then
  echo "It joined the tailnet as ${node#* }: remove the old $host node, then rename this one."
fi
if [ "$create" = 1 ]; then
  echo "New addresses: put $ipv4 and $ipv6 in dns/dnsconfig.js and, if it runs Headscale, modules/infra/headscale.nix."
fi
