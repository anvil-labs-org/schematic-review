#!/usr/bin/env bash
# Exit codes are semantic so gate logic can tell design failures from service
# problems: 0 passed or human step pending, 1 review gate failed, 3 error.
set -euo pipefail

api() { curl -sf --max-time 60 -H "Authorization: Bearer $ANVIL_API_KEY" "$@"; }

gh_api() {
  curl -sf --max-time 30 -H "Authorization: Bearer $GITHUB_TOKEN" \
    -H "Accept: application/vnd.github+json" -H "Content-Type: application/json" "$@"
}

# One comment per schematic, rewritten in place, so a matrix of boards does not
# stack a new comment per push. Needs pull-requests: write on the caller job.
marker="<!-- anvil-review:$SCHEMATIC_PATH -->"

sticky_comment_id() {
  local url="$GITHUB_API_URL/repos/$REPOSITORY/issues/$PR_NUMBER/comments" page=1 found=
  while [ "$page" -le 10 ]; do
    local batch
    batch=$(gh_api "$url?per_page=100&page=$page") || return 1
    [ "$(jq 'length' <<<"$batch")" -gt 0 ] || break
    found=$(jq -r --arg m "$marker" \
      'map(select(.body // "" | startswith($m))) | last | .id // empty' <<<"$batch")
    [ -n "$found" ] && { echo "$found"; return 0; }
    page=$((page + 1))
  done
  return 0
}

comment() {
  [ "${COMMENT,,}" = true ] && [ -n "${PR_NUMBER:-}" ] || return 0
  local body id
  body=$(jq -n --arg body "$marker"$'\n'"$1" '{$body}')
  id=$(sticky_comment_id) || id=
  if [ -n "$id" ]; then
    gh_api -X PATCH "$GITHUB_API_URL/repos/$REPOSITORY/issues/comments/$id" -d "$body" >/dev/null \
      && return 0
  else
    gh_api -X POST "$GITHUB_API_URL/repos/$REPOSITORY/issues/$PR_NUMBER/comments" -d "$body" >/dev/null \
      && return 0
  fi
  echo "::warning::Could not comment on PR #$PR_NUMBER — the job needs 'permissions: pull-requests: write'"
}

# Renders one markdown verdict for both the job summary and the PR comment.
report() {
  jq -r --arg path "$SCHEMATIC_PATH" --arg run "$WORKFLOW_RUN_URL" --arg sha "$COMMIT_SHA" '
    def counts:
      (.summary.by_severity // {}) as $b
      | ["critical", "major", "minor", "advisory"] as $known
      | (($known | map(select($b[.] != null))) + ($b | keys | map(select(IN($known[]) | not))))
      | map("\($b[.]) \(.)")
      | if length > 0 then " (" + join(", ") + ")" else "" end;
    def board: (.board.name // $path) + (if .board.revision then " · revision \(.board.revision)" else "" end);
    def found: (.summary.findings_total // 0) as $n
      | if $n == 0 then "no findings" else "\($n) finding\(if $n == 1 then "" else "s" end)\(counts)" end;
    "### Anvil schematic review — \(board)\n\n" +
    (if .status == "waiting" then
       "⏸️ **Needs a step in Anvil** — \(.detail // "a step is required before the review can continue").\n\n" +
       "[Open the review](\(.web_url))"
     elif .conclusion == "success" then
       "✅ **Passed** — \(found).\n\n" +
       "[View the report](\(.report_url // .web_url))"
     else
       "❌ **Issues found** — \(found).\n\n" +
       "[View the report](\(.report_url // .web_url))"
     end) +
    "\n\n<sub>`\($path)` at \($sha[0:7]) · [workflow run](\($run))</sub>"
  '
}

publish() {  # $1 = review payload
  local md
  md=$(report <<<"$1")
  echo "$md" | tee -a "$GITHUB_STEP_SUMMARY"
  comment "$md"
}

auto=true
# AUTO/STRICT/COMMENT come from action.yml's env block
# shellcheck disable=SC2153
[ "${AUTO,,}" = false ] && auto=false
body=$(jq -n \
  --arg repository "$REPOSITORY" --arg commit_sha "$COMMIT_SHA" \
  --arg schematic_path "$SCHEMATIC_PATH" --arg github_token "$GITHUB_TOKEN" \
  --arg workflow_run_url "$WORKFLOW_RUN_URL" \
  --argjson auto "$auto" --argjson pr_number "${PR_NUMBER:-null}" \
  '{$repository, $commit_sha, $schematic_path, $github_token,
    $workflow_run_url, $auto, $pr_number}')
review=$(curl -s --max-time 300 -H "Authorization: Bearer $ANVIL_API_KEY" \
  -X POST "$ANVIL_API/reviews" -H "Content-Type: application/json" -d "$body" \
  -w '\n%{http_code}' || true)
code=${review##*$'\n'}
review=${review%$'\n'*}
case "$code" in
  200|201) ;;
  *)
    detail=$(jq -r '.error.message // empty' <<<"$review" 2>/dev/null)
    echo "Could not create the review (HTTP ${code:-none}):" \
      "${detail:-no response — check the api-url input}"
    exit 3 ;;
esac
id=$(jq -r .id <<<"$review")
echo "Review: $(jq -r .web_url <<<"$review")"

for _ in $(seq 1 90); do  # ~45 min at 30s; polling also advances the pipeline
  if r=$(api "$ANVIL_API/reviews/$id"); then
    case "$(jq -r .status <<<"$r")" in
      completed)
        conclusion=$(jq -r .conclusion <<<"$r")
        publish "$r"
        [ "$conclusion" = success ] && exit 0
        # shellcheck disable=SC2153
        if [ "$conclusion" = failure ]; then
          [ "${STRICT,,}" = true ] && exit 1
          exit 0  # default: verdict reported in the summary, check stays green
        fi
        exit 3 ;;  # pipeline error — not a verdict on the design
      waiting)
        publish "$r"
        exit 0 ;;  # step linked in the summary, check stays green
    esac
  fi
  sleep 30
done
echo "Timed out waiting for the review"
exit 3
