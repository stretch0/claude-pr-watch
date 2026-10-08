# claude-pr-watch

A [Claude Code](https://claude.com/claude-code) plugin that keeps Claude responsible for the pull requests it pushes.

Without it, Claude pushes a branch, opens a PR, says "done", and forgets about it. With it:

- **After every push or `gh pr create`**, a hook reads the PR's CI and merge state and tells Claude what to do next. If checks are pending, Claude starts a background `gh pr checks --watch`, which wakes it up when they finish. If checks fail or the branch conflicts, Claude is told to fix it in the same turn.
- **When Claude tries to end the session**, a stop hook checks every PR the session pushed. If any has failing CI or a merge conflict, the session continues instead of stopping. It forces one continuation at most, so a failure Claude can't fix won't trap you.
- **`/pr-watch:babysit-pr`** makes one pass over a PR. It fixes failing CI, replies to and resolves review threads, rebases conflicts, and reports "merge-ready" when everything is clear.

None of it ever merges a PR or enables auto-merge. That stays with you.

## Requirements

- [GitHub CLI](https://cli.github.com/) (`gh`), logged in to an account that can read the repo
- `git`, `bash` and `python3` on your `PATH`

## Install

```
/plugin marketplace add stretch0/claude-pr-watch
/plugin install pr-watch@stretch0
```

This installs at **user scope** by default, so it applies to every project you open and nobody else is affected. To share it with everyone on a repo instead, pick project scope during install. That records it in the repo's `.claude/settings.json`.

Turn it off with `/plugin disable pr-watch@stretch0`, or disable it at local scope for a single repo that has its own PR hooks.

## Watching review comments

The hooks react to pushes and to the end of a session. They do not notice new review comments arriving on their own. To keep working through review feedback while you do something else, loop the skill:

```
/loop 10m /pr-watch:babysit-pr 123
```

Each pass caps itself at 3 fix attempts per failure type, and escalates design questions, security findings and deployment failures to you instead of guessing.

## Configuration

| Environment variable | Default | Effect |
| --- | --- | --- |
| `PR_WATCH_REQUIRE_SIGNED` | unset | Set to `1` to also check that GitHub verified the pushed commit's signature, and tell Claude to fix it when it didn't. |

Set it in your shell, or under `env` in `~/.claude/settings.json`.

## How it works

`hooks/post-push-pr-status.sh` runs after each Bash call. It returns immediately unless the command is a `git push` or `gh pr create`. On a match, it records the branch in a per-session file under `$TMPDIR` and returns the PR status to Claude as extra context.

`hooks/stop-pr-gate.sh` runs when Claude tries to stop. It reads that per-session file, looks up each PR, and blocks the stop if any open PR is red or conflicting. Pending checks never block, because the background watcher already handles them. Entries expire after 48 hours, and closed or merged PRs are dropped.

## License

MIT
