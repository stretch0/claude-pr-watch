#!/usr/bin/env bash
# stop-pr-gate.sh: refuse to end the session while a branch this session
# pushed has an open PR with failing checks or a merge conflict.
#
# Runs as a Stop hook. Reads the per-session state file written by
# post-push-pr-status.sh. Pending checks never block: the background
# `gh pr checks --watch` task owns that case, and blocking here would fight
# its completion notification. `stop_hook_active` allows exactly one forced
# continuation, so a failure Claude cannot fix does not trap the session.
#
# Always exits 0; blocking is expressed as {"decision": "block"} JSON.

set -u

INPUT=$(cat)

PARSED=$(echo "$INPUT" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    print(data.get('session_id', ''))
    print('true' if data.get('stop_hook_active') else 'false')
except Exception:
    pass
" 2>/dev/null) || exit 0

{ read -r SESSION_ID; read -r STOP_HOOK_ACTIVE; } <<< "$PARSED"

[[ -z "$SESSION_ID" ]] && exit 0
[[ "$STOP_HOOK_ACTIVE" == "true" ]] && exit 0

STATE_FILE="${TMPDIR:-/tmp}/claude-pr-watch-${SESSION_ID}.tsv"
[[ -s "$STATE_FILE" ]] || exit 0

# Every surviving line costs a network call on every stop, so lines age out
# after 48h and closed or merged PRs are pruned as soon as they are seen.
MAX_LINE_AGE=172800
NOW=$(date +%s)
KEEP=""
FAILING=""
CONFLICTED=""

while IFS=$'\t' read -r DIR BRANCH TS; do
    [[ -d "$DIR" ]] || continue
    [[ "${TS:-}" =~ ^[0-9]+$ ]] && (( NOW - TS > MAX_LINE_AGE )) && continue

    PR_JSON=$(cd "$DIR" && gh pr view "$BRANCH" --json number,url,state,statusCheckRollup,mergeable 2>/dev/null || echo "")
    if [[ -z "$PR_JSON" ]]; then
        # Lookup failed or no PR yet: keep the line for the next stop.
        KEEP="${KEEP}${DIR}	${BRANCH}	${TS:-$NOW}
"
        continue
    fi

    # Line 1 is the PR state, line 2 the verdict.
    VERDICT_OUT=$(python3 -c "
import json, sys
pr = json.loads(sys.argv[1])
print(pr.get('state', ''))
if pr.get('state') != 'OPEN':
    print('OK')
    raise SystemExit
# A conflict outranks check results: those ran against a base this branch
# can no longer merge into, and nothing else is watching for it.
if pr.get('mergeable') == 'CONFLICTING':
    print(f\"CONFLICT\tPR #{pr['number']} ({pr['url']}) conflicts with its base\")
    raise SystemExit
bad = [
    c.get('name') or c.get('context') or '?'
    for c in pr.get('statusCheckRollup') or []
    if c.get('status') == 'COMPLETED'
    and c.get('conclusion') not in ('SUCCESS', 'NEUTRAL', 'SKIPPED')
]
print(f\"FAIL\tPR #{pr['number']} ({pr['url']}) failing: {', '.join(bad)}\" if bad else 'OK')
" "$PR_JSON" 2>/dev/null || echo "")

    { read -r PR_STATE; read -r VERDICT; } <<< "$VERDICT_OUT"

    case "$PR_STATE" in
        CLOSED | MERGED) ;;
        *)
            KEEP="${KEEP}${DIR}	${BRANCH}	${TS:-$NOW}
"
            ;;
    esac

    case "$VERDICT" in
        CONFLICT*) CONFLICTED="${CONFLICTED}${VERDICT#CONFLICT	}; " ;;
        FAIL*) FAILING="${FAILING}${VERDICT#FAIL	}; " ;;
    esac
done < <(sort -u "$STATE_FILE")

printf '%b' "$KEEP" > "$STATE_FILE" 2>/dev/null || true

[[ -z "$FAILING" ]] && [[ -z "$CONFLICTED" ]] && exit 0

python3 -c "
import json, sys
failing, conflicted = sys.argv[1], sys.argv[2]
parts = []
if conflicted:
    parts.append(
        'A PR this session pushed conflicts with its base: ' + conflicted
        + 'Rebase onto the base branch and resolve by provenance (this branch '
        + 'owns its new code, the base owns shared config), re-run the affected '
        + 'checks, then push with --force-with-lease. A hunk you cannot '
        + 'attribute is the user\'s call, not a guess.'
    )
if failing:
    parts.append(
        'A PR this session pushed has failing CI: ' + failing
        + 'Fix the failing checks before ending the session, or start a '
        + 'background gh pr checks --watch task if a fix is already pushed.'
    )
parts.append('Never merge.')
print(json.dumps({'decision': 'block', 'reason': ' '.join(parts)}))
" "$FAILING" "$CONFLICTED" 2>/dev/null

exit 0
