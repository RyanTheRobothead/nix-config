#!/usr/bin/env bash
# Compare every record in dnsconfig.js with what a nameserver actually serves.
#
#   dns/verify.sh <zone> [nameserver]
#
# The nameserver defaults to the zone's first public NS, so with no argument
# this checks what the internet sees today. Point it at ns1.desec.io to check
# deSEC before switching nameservers. Exits non-zero if any record set
# differs; TTL-only differences are reported but don't fail.
set -euo pipefail

zone=${1:?usage: dns/verify.sh <zone> [nameserver]}
ns=${2:-$(dig +short NS "$zone" | head -1)}
cd "$(dirname "$0")"
want_file=$(mktemp)
trap 'rm -f "$want_file"' EXIT

# name<TAB>type<TAB>ttl<TAB>rdata, in the presentation format dig prints.
dnscontrol print-ir --config dnsconfig.js 2>/dev/null |
  jq -r --arg z "$zone" '
    .domains[] | select(.name == $z) | .records[]
    | select(.type != "NS")
    | [ .name, .type, (.ttl | tostring),
        ( if .type == "MX" then "\(.mxpreference) \(.target)"
          elif .type == "TXT" then (.txtstrings // [.target] | map("\"" + . + "\"") | join(" "))
          else .target end ) ]
    | @tsv' |
  sort -u > "$want_file"

fail=0
while IFS=$'\t' read -r name type; do
  fqdn=$([ "$name" = "@" ] && echo "$zone." || echo "$name.$zone.")
  # A wildcard is checked through a name that only it can answer.
  [ "$name" = "*" ] && fqdn="dns-verify-wildcard-probe.$zone."
  want=$(awk -F'\t' -v n="$name" -v t="$type" '$1 == n && $2 == t { print $4 }' "$want_file" | sort)
  wttl=$(awk -F'\t' -v n="$name" -v t="$type" '$1 == n && $2 == t { print $3 }' "$want_file" | sort -u | head -1)
  answer=$(dig +noall +answer +norecurse "$type" "$fqdn" @"$ns" | awk -v t="$type" '$4 == t')
  have=$(echo "$answer" | awk '{ $1 = $2 = $3 = $4 = ""; sub(/^ +/, ""); print }' | sed '/^$/d' | sort)
  have_line=${have//$'\n'/ | }
  httl=$(echo "$answer" | awk 'NR == 1 { print $2 }')
  if [ "$want" != "$have" ]; then
    fail=1
    printf 'DIFF  %-45s %-5s\n  want: %s\n  have: %s\n' "$name" "$type" "${want//$'\n'/ | }" "${have_line:-<nothing>}"
  elif [ "$wttl" != "$httl" ]; then
    printf 'TTL   %-45s %-5s want %s, have %s\n' "$name" "$type" "$wttl" "$httl"
  else
    printf 'ok    %-45s %s\n' "$name" "$type"
  fi
done < <(cut -f1,2 "$want_file" | sort -u)

echo "checked $zone against $ns"
exit $fail
