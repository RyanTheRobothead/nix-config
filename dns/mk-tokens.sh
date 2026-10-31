#!/usr/bin/env bash
# Create the scoped deSEC tokens and store each one where it is used.
#
#   nix develop .#dns -c dns/mk-tokens.sh
#
# It asks for a manager token (or reads DESEC_MANAGER_TOKEN): a short-lived
# token made in deSEC's web UI with "manage tokens" and a max age of an hour;
# delete it afterwards. Token values
# are only ever piped into sops, gh or a 0600 file, never printed. deSEC shows
# a token's secret once, at creation, so if anything fails before every value
# is stored, the tokens made so far are deleted again.
#
# Policies match subname exactly, so an ACME token can answer for the apex and
# the wildcard (both use _acme-challenge) but not for a.b.<zone>. Every token
# can read every record; only writes are scoped.
#
#   ci-preview   read-only              repo secret DESEC_PREVIEW_TOKEN, and
#                                       ~/.config/desec/token for local preview
#   ci-apply     write on the 3 zones   secret DESEC_APPLY_TOKEN in the GitHub
#                                       environment "dns" (main only), and
#                                       secrets/desec.yaml for a manual push
#   acme-aegis   _acme-challenge TXT    secrets/desec.yaml
#                on ryandlewis.dev
#   acme-sleeperservice  _acme-challenge TXT on all 3 zones
#                                       secrets/sleeperservice/desec.yaml
#                                       (admin keys only until the host exists)
#
# None of them can manage tokens or create or delete domains, and none expire:
# ACME tokens sit idle for a month or two between renewals.
set -euo pipefail

if [ -z "${DESEC_MANAGER_TOKEN:-}" ] && [ -t 0 ]; then
  read -rsp 'deSEC manager token: ' DESEC_MANAGER_TOKEN
  echo
fi
: "${DESEC_MANAGER_TOKEN:?set DESEC_MANAGER_TOKEN to a token with manage-tokens permission}"
cd "$(dirname "$0")/.."

ZONES=(ryandlewis.dev robothead.dev luckierdodge.dev)
REPO=RyanTheRobothead/nix-config
API=https://desec.io/api/v1

for f in secrets/desec.yaml secrets/sleeperservice/desec.yaml; do
  [ ! -e "$f" ] || { echo "$f already exists; delete the old tokens and it first" >&2; exit 1; }
done

api() {
  local out
  if ! out=$(curl -sS --fail-with-body \
    -H @<(printf 'Authorization: Token %s\n' "$DESEC_MANAGER_TOKEN") \
    -H 'Content-Type: application/json' "$API$1" "${@:2}"); then
    echo "deSEC $1: $out" >&2
    return 1
  fi
  printf '%s\n' "$out"
}

existing=$(api /auth/tokens/ | jq -r '.[].name')

created=()
done=0
cleanup() {
  [ "$done" = 1 ] && return
  rm -f secrets/desec.yaml.new secrets/sleeperservice/desec.yaml.new
  for id in "${created[@]}"; do
    echo "deleting token $id" >&2
    api "/auth/tokens/$id/" -X DELETE >/dev/null || echo "  failed: delete it in the web UI" >&2
  done
}
trap cleanup EXIT

declare -A secret
# mk <name> <policy JSON>...: the default policy (write denied) comes first.
mk() {
  local name="nix-config $1" id resp
  shift
  if grep -qxF "$name" <<<"$existing"; then
    echo "a token named \"$name\" already exists; delete it first" >&2
    exit 1
  fi
  resp=$(api /auth/tokens/ -X POST --data "$(jq -n --arg n "$name" '{name: $n,
    perm_manage_tokens: false, perm_create_domain: false, perm_delete_domain: false,
    max_age: null, max_unused_period: null}')")
  id=$(jq -r .id <<<"$resp")
  created+=("$id")
  secret[$name]=$(jq -r .token <<<"$resp")
  for policy in '{"domain": null, "subname": null, "type": null, "perm_write": false}' "$@"; do
    api "/auth/tokens/$id/policies/rrsets/" -X POST --data "$policy" >/dev/null
  done
  echo "created \"$name\" ($id) with $(( $# + 1 )) policies"
}

zone_write() { jq -nc --arg d "$1" '{domain: $d, subname: null, type: null, perm_write: true}'; }
acme_write() { jq -nc --arg d "$1" '{domain: $d, subname: "_acme-challenge", type: "TXT", perm_write: true}'; }

mapfile -t apply_policies < <(for z in "${ZONES[@]}"; do zone_write "$z"; done)
mapfile -t acme_policies < <(for z in "${ZONES[@]}"; do acme_write "$z"; done)
mk ci-preview
mk ci-apply "${apply_policies[@]}"
mk acme-aegis "$(acme_write ryandlewis.dev)"
mk acme-sleeperservice "${acme_policies[@]}"

# sops encrypts to public keys only, so no YubiKey touch here.
printf 'desec_token_ci_apply: "%s"\ndesec_token_acme_aegis: "%s"\n' \
  "${secret[nix-config ci-apply]}" "${secret[nix-config acme-aegis]}" |
  sops encrypt --filename-override secrets/desec.yaml /dev/stdin > secrets/desec.yaml.new
mkdir -p secrets/sleeperservice
printf 'desec_token_acme_sleeperservice: "%s"\n' "${secret[nix-config acme-sleeperservice]}" |
  sops encrypt --filename-override secrets/sleeperservice/desec.yaml /dev/stdin \
  > secrets/sleeperservice/desec.yaml.new

# Only main may deploy to the dns environment, so PR runs never see the
# write token.
gh api -X PUT "repos/$REPO/environments/dns" --input - >/dev/null <<<'
  {"deployment_branch_policy": {"protected_branches": false, "custom_branch_policies": true}}'
gh api "repos/$REPO/environments/dns/deployment-branch-policies" -q '.branch_policies[].name' |
  grep -qxF main ||
  gh api -X POST "repos/$REPO/environments/dns/deployment-branch-policies" -f name=main >/dev/null
printf '%s' "${secret[nix-config ci-apply]}" | gh secret set DESEC_APPLY_TOKEN --repo "$REPO" --env dns
printf '%s' "${secret[nix-config ci-preview]}" | gh secret set DESEC_PREVIEW_TOKEN --repo "$REPO"

mv secrets/desec.yaml.new secrets/desec.yaml
mv secrets/sleeperservice/desec.yaml.new secrets/sleeperservice/desec.yaml
mkdir -p ~/.config/desec
(umask 077 && printf '%s\n' "${secret[nix-config ci-preview]}" > ~/.config/desec/token.new)
mv ~/.config/desec/token.new ~/.config/desec/token
done=1

echo "stored: secrets/desec.yaml, secrets/sleeperservice/desec.yaml, GitHub secrets, ~/.config/desec/token (read-only)"
