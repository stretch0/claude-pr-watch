---
name: babysit-pr
description: One bounded pass over a GitHub PR. Check CI, address review feedback, resolve conflicts, report. Loop-compatible; run the long-running form as /loop <interval> /pr-watch:babysit-pr <n>.
argument-hint: <PR number, or blank to detect from the current branch>
---

Make one bounded pass over a PR's outstanding work, then stop. This skill
never polls or sleeps. Within a session, the plugin's push hook and background
`gh pr checks --watch` tasks deliver events. Across sessions,
`/loop <interval> /pr-watch:babysit-pr <n>` re-invokes it on a cadence. Each
invocation does a full pass and ends with a status report.

## The pass

1. **Resolve the PR** from `$ARGUMENTS`, else from the current branch
   (`gh pr list --head <branch> --state open`). No open PR: report and stop.
   Resolve `headRefName` and work on a checkout of it. If the current working
   tree is not on the PR's head branch, use (or add) a git worktree for it,
   because a fix committed to whatever branch happened to be checked out
   lands on the wrong PR.
2. **Read state once**: `gh pr view <n> --json state,mergeable,reviewDecision,statusCheckRollup`,
   plus the review threads with their resolution state through GraphQL
   (`reviewThreads { nodes { id isResolved comments { ... } } }`).
   `reviewDecision` is an aggregate and cannot see unresolved threads.
3. **Act on what the state demands**, in this order:
   - **Failing CI**: fetch the failing job's logs (`gh run view <id> --log-failed`),
     classify the failure (lint, typecheck, test, build, or other), fix the
     root cause, commit `fix: address CI failure (<category>)`, and push.
     Cap: 3 attempts per failure class across all passes, counted from this
     skill's own PR comments (see Audit trail). Never auto-fix deploy
     failures, security findings, or failures you cannot classify; escalate
     those.
   - **Unresolved review threads**: every thread gets a posted reply and is
     then resolved. For actionable feedback, make the change, push, and
     reply with what changed. For a question, answer it in the thread. If
     you disagree with a suggestion, reply with the reasoning and leave the
     thread open for the reviewer.
   - **Merge conflicts**: rebase onto the base branch, resolving by
     provenance (this branch owns its new code; the base owns shared
     config). Verify the result builds, then push with `--force-with-lease`.
     A rebase rewrites pushed history, so a plain push is rejected, and the
     lease aborts if someone else moved the branch meanwhile. Force-push
     only the PR's own head branch, never a base or shared branch.
   - **Pending checks**: pending is not proof of progress. Before watching,
     read the run's jobs (`gh api repos/{owner}/{repo}/actions/runs/<id>/jobs`)
     and check the current step. A job stuck on one step far beyond its
     normal duration is hung, not slow: cancel the run and
     `gh run rerun <id> --failed` instead of waiting on it. For checks that
     are progressing, start `gh pr checks <n> --watch` as a background task
     and end the pass; the completion notification carries the result. The
     watch snapshots the checks that exist when it starts, and later
     pipeline stages can register their jobs late, so confirm the expected
     jobs are present first and re-read the rollup once the watch concludes.
     Run one watcher per PR, and stop any watcher a new one supersedes.
4. **Report**: one line per action taken, plus the PR's resulting state.
   When checks are green, no review threads are unresolved and there are no
   conflicts, report "merge-ready" and nothing else. Never merge and never
   enable auto-merge.

## Escalate instead of acting when

- The fix requires a design or product judgment.
- A failure class has hit its 3-attempt cap.
- The feedback is security-related or touches deployment.

When you escalate a review thread, also reply in the thread saying it is
waiting on a human decision. The plugin's stop hook counts unresolved threads
whose last comment is not yours, so an unanswered escalated thread keeps
blocking the session from ending.

## Audit trail

Every push or thread resolution made by a pass gets a PR comment naming what
was done and which pass attempt it was, so the attempt caps hold across
invocations and sessions.
