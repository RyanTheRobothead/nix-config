# Runs after every Renovate run (renovate.nix). Posts to Discord when the run
# failed, when a Dependency Dashboard lists a branch under "Errored" that it
# didn't last time, and weekly while a branch stays errored. Set DRY_RUN to
# print messages instead of posting them.

STATE="${STATE_DIRECTORY:-/var/lib/renovate-check}/errored.json"
TOKEN_FILE="${CREDENTIALS_DIRECTORY:-}/github-token"
WEBHOOK_FILE="${CREDENTIALS_DIRECTORY:-}/discord-webhook"
REMIND_AFTER=$((7 * 24 * 3600))

post() {
  local content=$1
  if [[ -n "${DRY_RUN:-}" ]]; then
    printf '%s\n---\n' "$content"
    return
  fi
  jq -n --arg c "$content" --arg u "${PING_USER:-}" \
    '{content: $c, allowed_mentions: {parse: [], users: (if $u == "" then [] else [$u] end)}}' |
    curl -fsS -H 'Content-Type: application/json' -H 'User-Agent: renovate-check' \
      --data-binary @- "$(cat "$WEBHOOK_FILE")" >/dev/null
}

mention() { [[ -n "${PING_USER:-}" ]] && printf '<@%s> ' "$PING_USER"; }

result=$(systemctl show renovate.service -p Result --value 2>/dev/null || echo unknown)
if [[ "$result" != "success" ]]; then
  post "$(mention)**Renovate failed** on $(hostname) (result: $result); see \`journalctl -u renovate\`"
fi

now=$(date +%s)
[[ -s "$STATE" ]] || echo '{}' >"$STATE"
current='{}'
for repo in $RENOVATE_REPOS; do
  # Branches listed under "## Errored", as {"<repo> <branch>": "<title>"}
  errored=$(
    curl -fsS -H "Authorization: Bearer $(cat "$TOKEN_FILE")" \
      -H 'Accept: application/vnd.github+json' \
      "https://api.github.com/repos/$repo/issues?state=open&per_page=100" |
      jq --arg repo "$repo" '
        [.[] | select(.title == "Dependency Dashboard" and .pull_request == null)][0].body // ""
        | split("\n## ") | map(select(startswith("Errored"))) | .[0] // ""
        | [scan("retry-branch=(\\S+) -->(.*)")]
        | map({key: "\($repo) \(.[0])", value: .[1]}) | from_entries'
  ) || {
    post "$(mention)**renovate-check** couldn't read $repo's Dependency Dashboard on $(hostname)"
    continue
  }
  current=$(jq -n --argjson a "$current" --argjson b "$errored" '$a + $b')
done

# Alert on new branches, and remind about ones errored for another week
due=$(jq -n --argjson cur "$current" --argjson seen "$(cat "$STATE")" \
  --argjson now "$now" --argjson remind "$REMIND_AFTER" '
  $cur | to_entries
  | map(.key as $k | select(($seen | has($k) | not) or $seen[$k].alerted + $remind <= $now))
  | map({key, title: .value, since: ($seen[.key].since // $now)})')
if [[ $(jq length <<<"$due") -gt 0 ]]; then
  lines=$(jq -r --argjson now "$now" '.[] |
    "- \(.key | split(" ")[0]): `\(.key | split(" ")[1])` (\(.title)), errored "
    + (if .since == $now then "since this run" else "for \((($now - .since) / 86400) | floor) days" end)' <<<"$due")
  post "$(mention)**Renovate can't update $(jq length <<<"$due") branch(es)**; see each repo's Dependency Dashboard:
$lines"
fi

# Keep only what is still errored
jq -n --argjson cur "$current" --argjson seen "$(cat "$STATE")" --argjson due "$due" --argjson now "$now" '
  $cur | to_entries | map(.key as $k | {key: $k, value: {
    since: ($seen[$k].since // $now),
    alerted: (if any($due[]; .key == $k) then $now else ($seen[$k].alerted // $now) end)
  }}) | from_entries' >"$STATE.tmp"
mv "$STATE.tmp" "$STATE"
