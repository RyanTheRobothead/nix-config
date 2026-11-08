# Runs after every Renovate run (renovate.nix). Posts to ntfy's `updates`
# topic when the run failed, when a Dependency Dashboard lists a branch under
# "Errored" that it didn't last time, and weekly while a branch stays errored.
# Set DRY_RUN to print messages instead of posting them.

STATE="${STATE_DIRECTORY:-/var/lib/renovate-check}/errored.json"
TOKEN_FILE="${CREDENTIALS_DIRECTORY:-}/github-token"
NTFY_TOKEN_FILE="${CREDENTIALS_DIRECTORY:-}/ntfy-token"
REMIND_AFTER=$((7 * 24 * 3600))

# Tokens go to curl as header files, not arguments, so they stay out of
# /proc/*/cmdline
bearer() { printf 'Authorization: Bearer %s' "$(cat "$1")"; }

# post PRIORITY TITLE BODY
post() {
  local msg
  msg=$(jq -n --argjson p "$1" --arg t "$2" --arg m "$3" \
    '{topic: "updates", priority: $p, title: $t, message: $m, markdown: true, tags: ["arrows_counterclockwise"]}')
  if [[ -n "${DRY_RUN:-}" ]]; then
    printf '%s\n' "$msg"
    return
  fi
  curl -fsS -H 'Content-Type: application/json' -H 'User-Agent: renovate-check' \
    -H @<(bearer "$NTFY_TOKEN_FILE") --data-binary "$msg" "$NTFY_URL" >/dev/null
}

result=$(systemctl show renovate.service -p Result --value 2>/dev/null || echo unknown)
if [[ "$result" != "success" ]]; then
  post 4 "Renovate failed on $(hostname)" "Result: $result. See \`journalctl -u renovate\`."
fi

now=$(date +%s)
[[ -s "$STATE" ]] || echo '{}' >"$STATE"
current='{}'
for repo in $RENOVATE_REPOS; do
  # Branches listed under "## Errored", as {"<repo> <branch>": "<title>"}
  errored=$(
    curl -fsS -H @<(bearer "$TOKEN_FILE") \
      -H 'Accept: application/vnd.github+json' \
      "https://api.github.com/repos/$repo/issues?state=open&per_page=100" |
      jq --arg repo "$repo" '
        [.[] | select(.title == "Dependency Dashboard" and .pull_request == null)][0].body // ""
        | split("\n## ") | map(select(startswith("Errored"))) | .[0] // ""
        | [scan("retry-branch=(\\S+) -->(.*)")]
        | map({key: "\($repo) \(.[0])", value: .[1]}) | from_entries'
  ) || {
    post 3 "renovate-check couldn't read $repo's Dependency Dashboard" "On $(hostname); see \`journalctl -u renovate-check\`."
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
  post 4 "Renovate can't update $(jq length <<<"$due") branch(es)" "See each repo's Dependency Dashboard:
$lines"
fi

# Keep only what is still errored
jq -n --argjson cur "$current" --argjson seen "$(cat "$STATE")" --argjson due "$due" --argjson now "$now" '
  $cur | to_entries | map(.key as $k | {key: $k, value: {
    since: ($seen[$k].since // $now),
    alerted: (if any($due[]; .key == $k) then $now else ($seen[$k].alerted // $now) end)
  }}) | from_entries' >"$STATE.tmp"
mv "$STATE.tmp" "$STATE"
