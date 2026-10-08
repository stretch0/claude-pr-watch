#!/usr/bin/env bash
# post-push-pr-status.sh: after `gh pr create`, or after `git push` to a branch
# that already has a PR, inject the PR's CI and conflict status into the turn
# so follow-up is deterministic rather than remembered.
#
# Runs as a PostToolUse hook on Bash and receives the tool input JSON on stdin.
# Emits hook JSON with additionalContext on a match; silent otherwise. A bare
# push with no PR is silent by design: the push usually precedes the PR
# create, so there is nothing to watch yet.
#
# Set PR_WATCH_REQUIRE_SIGNED=1 to also check that GitHub verified the pushed
# commit's signature.
#
# Always exits 0: a status watcher must never fail the turn it reports on.

set -u

INPUT=$(cat)

# Cheap prefilter before any process spawn: this hook runs on every Bash call
# and almost none of them push or create a PR. The anchored regexes below
# make the real decision.
case "$INPUT" in
    *push* | *"pr create"*) ;;
    *) exit 0 ;;
esac

PARSED=$(echo "$INPUT" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    tool_input = data.get('tool_input', data)
    print(tool_input.get('command', '').replace('\n', ' '))
    print(data.get('cwd', ''))
    print(data.get('session_id', ''))
except Exception:
    pass
" 2>/dev/null) || exit 0

{ read -r COMMAND; read -r CWD; read -r SESSION_ID; } <<< "$PARSED"

# Anchored to command position (start, or after ; & | ( or a backtick) so
# that `echo git push` does not trigger network calls.
PUSH_RE='(^|[;&|(`])[[:space:]]*git([[:space:]]+-C[[:space:]]+[^[:space:]]+)?[[:space:]]+push'
CREATE_RE='(^|[;&|(`])[[:space:]]*gh[[:space:]]+pr[[:space:]]+create'

EVENT=""
DASH_C=""
if [[ "$COMMAND" =~ $CREATE_RE ]]; then
    EVENT="create"
elif [[ "$COMMAND" =~ $PUSH_RE ]]; then
    EVENT="push"
    # Group 2 is the optional " -C <path>" clause; its last word is the path.
    DASH_C="${BASH_REMATCH[2]##* }"
else
    exit 0
fi

[[ -n "$CWD" ]] && [[ -d "$CWD" ]] || CWD="$PWD"
# `git -C <path> push` targets <path> whatever the shell's cwd is.
if [[ -n "$DASH_C" ]] && [[ -d "$DASH_C" ]]; then
    CWD="$DASH_C"
fi

BRANCH=$(git -C "$CWD" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
SHA=$(git -C "$CWD" rev-parse HEAD 2>/dev/null || echo "")

# Record the pushed branch so stop-pr-gate.sh knows which PRs this session
# is responsible for.
if [[ -n "$SESSION_ID" ]] && [[ -n "$BRANCH" ]] && [[ "$BRANCH" != "HEAD" ]]; then
    STATE_FILE="${TMPDIR:-/tmp}/claude-pr-watch-${SESSION_ID}.tsv"
    if ! grep -qsF "$CWD	$BRANCH" "$STATE_FILE" 2>/dev/null; then
        printf '%s\t%s\t%s\n' "$CWD" "$BRANCH" "$(date +%s)" >> "$STATE_FILE" 2>/dev/null || true
    fi
fi

SIG="skipped"
SIG_PID=""
SIG_FILE=""
if [[ "${PR_WATCH_REQUIRE_SIGNED:-0}" == "1" ]] && [[ -n "$SHA" ]]; then
    # Independent of the PR read below, so run it concurrently.
    SIG_FILE=$(mktemp)
    (cd "$CWD" && gh api "repos/{owner}/{repo}/commits/$SHA" --jq .commit.verification.verified 2>/dev/null > "$SIG_FILE") &
    SIG_PID=$!
fi

PR_JSON=$(cd "$CWD" && gh pr view --json number,url,state,statusCheckRollup,mergeable 2>/dev/null || echo "")

if [[ -n "$SIG_PID" ]]; then
    wait "$SIG_PID" 2>/dev/null
    SIG=$(cat "$SIG_FILE" 2>/dev/null)
    rm -f "$SIG_FILE"
    [[ -n "$SIG" ]] || SIG="unknown"
fi

if [[ -z "$PR_JSON" ]] && [[ "$EVENT" == "push" ]]; then
    exit 0
fi

python3 - "$BRANCH" "$SHA" "$SIG" "$PR_JSON" <<'PY' 2>/dev/null || exit 0
import json
import sys

branch, sha, sig, pr_raw = sys.argv[1:5]

lines = [f"A push/PR event just ran on branch `{branch}` (HEAD {sha[:12]})."]

if pr_raw:
    pr = json.loads(pr_raw)
    rollup = pr.get("statusCheckRollup") or []
    pending = sum(1 for c in rollup if c.get("status") != "COMPLETED")
    failed = sum(
        1
        for c in rollup
        if c.get("status") == "COMPLETED"
        and c.get("conclusion") not in ("SUCCESS", "NEUTRAL", "SKIPPED")
    )
    passed = len(rollup) - pending - failed
    lines.append(
        f"PR #{pr['number']} ({pr['state']}) {pr['url']}: checks "
        f"{passed} passed, {failed} failed, {pending} pending."
    )
    number = pr["number"]
    # GitHub computes mergeability asynchronously, so right after a push the
    # answer is often UNKNOWN. Only CONFLICTING is actionable.
    conflicting = pr.get("mergeable") == "CONFLICTING"
else:
    lines.append(
        "The PR could not be read back yet. Confirm creation succeeded, then "
        "run `gh pr checks <number>` for status."
    )
    number = "<number>"
    conflicting = False

lines.append("Required follow-up before ending the turn:")
if conflicting:
    lines.append(
        "- This PR CONFLICTS with its base. Rebase it onto the base branch now "
        "rather than reporting the conflict and stopping. Resolve by provenance "
        "(this branch owns its new code, the base owns shared config), re-run "
        "the affected checks, and push with --force-with-lease. A hunk you "
        "cannot attribute is the user's call, not a guess."
    )
if sig not in ("true", "skipped"):
    lines.append(
        "- The pushed commit is NOT verified on GitHub. Fix the committer "
        "identity or signing setup, amend, and push again."
    )
lines.append(
    f"- If any check is pending, start `gh pr checks {number} --watch` as a "
    "background Bash task now; its completion re-invokes you with the result, "
    "so the conclusion arrives without polling. If any check fails, fix it "
    "now rather than reporting and stopping."
)
lines.append("- Never merge or enable auto-merge; report the final status to the user.")

print(
    json.dumps(
        {
            "hookSpecificOutput": {
                "hookEventName": "PostToolUse",
                "additionalContext": "\n".join(lines),
            }
        }
    )
)
PY

exit 0
