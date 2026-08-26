#!/usr/bin/env bash
# Exit codes are semantic so gate logic can tell design failures from service
# problems: 0 passed or human step pending, 1 review gate failed, 3 error.
set -euo pipefail

api() { curl -sf --max-time 60 -H "Authorization: Bearer $ANVIL_API_KEY" "$@"; }

auto=true
# AUTO/STRICT come from action.yml's env block
# shellcheck disable=SC2153
[ "${AUTO,,}" = false ] && auto=false
body=$(jq -n \
  --arg repository "$REPOSITORY" --arg commit_sha "$COMMIT_SHA" \
  --arg schematic_path "$SCHEMATIC_PATH" --arg github_token "$GITHUB_TOKEN" \
  --arg workflow_run_url "$WORKFLOW_RUN_URL" \
  --argjson auto "$auto" --argjson pr_number "${PR_NUMBER:-null}" \
  '{$repository, $commit_sha, $schematic_path, $github_token,
    $workflow_run_url, $auto, $pr_number}')
review=$(api -X POST "$ANVIL_API/reviews" -H "Content-Type: application/json" -d "$body") \
  || { echo "Could not create the review — check the api-key and api-url inputs"; exit 3; }
id=$(jq -r .id <<<"$review")
echo "Review: $(jq -r .web_url <<<"$review")"

for _ in $(seq 1 90); do  # ~45 min at 30s; polling also advances the pipeline
  if r=$(api "$ANVIL_API/reviews/$id"); then
    case "$(jq -r .status <<<"$r")" in
      completed)
        conclusion=$(jq -r .conclusion <<<"$r")
        { echo "## Anvil schematic review: $conclusion"
          jq -r '"Findings: \(.summary.findings_total // 0) — \(.report_url // .web_url)"' <<<"$r"
        } | tee -a "$GITHUB_STEP_SUMMARY"
        [ "$conclusion" = success ] && exit 0
        # shellcheck disable=SC2153
        if [ "$conclusion" = failure ]; then
          [ "${STRICT,,}" = true ] && exit 1
          exit 0  # default: verdict reported in the summary, check stays green
        fi
        exit 3 ;;  # pipeline error — not a verdict on the design
      waiting)
        { echo "## Anvil review needs a human step"
          jq -r '"\(.detail // "A step is required in Anvil") — \(.web_url)"' <<<"$r"
        } | tee -a "$GITHUB_STEP_SUMMARY"
        exit 0 ;;  # step linked in the summary, check stays green
    esac
  fi
  sleep 30
done
echo "Timed out waiting for the review"
exit 3
