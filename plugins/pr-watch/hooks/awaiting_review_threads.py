"""Print how many unresolved review threads on a PR are waiting on a reply.

Usage: python3 awaiting_review_threads.py <pr-url>

A thread whose last comment is by the authenticated gh user is waiting on the
reviewer, not on us, so it does not count. That is what stops the gate from
looping on a thread Claude has already answered and deliberately left open.

Prints nothing when GitHub cannot be read, so callers treat silence as
"unknown" rather than as zero.
"""

import json
import subprocess
import sys
from urllib.parse import urlparse

QUERY = """
query($owner: String!, $repo: String!, $number: Int!) {
  viewer { login }
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $number) {
      reviewThreads(first: 100) {
        nodes {
          isResolved
          comments(last: 1) { nodes { author { login } } }
        }
      }
    }
  }
}
"""


def fetch_review_threads(pr_url: str) -> dict:
    url = urlparse(pr_url)
    owner, repo, _, number = url.path.strip("/").split("/")[:4]
    result = subprocess.run(
        [
            "gh", "api", "graphql",
            "--hostname", url.hostname or "github.com",
            "-f", f"query={QUERY}",
            "-f", f"owner={owner}",
            "-f", f"repo={repo}",
            "-F", f"number={number}",
        ],
        capture_output=True,
        text=True,
        timeout=20,
        check=True,
    )
    return json.loads(result.stdout)["data"]


def last_author(thread: dict) -> str:
    comments = thread["comments"]["nodes"]
    author = comments[-1].get("author") if comments else None
    return (author or {}).get("login", "")


def count_awaiting(data: dict) -> int:
    me = data["viewer"]["login"]
    threads = data["repository"]["pullRequest"]["reviewThreads"]["nodes"]
    return sum(1 for t in threads if not t["isResolved"] and last_author(t) != me)


def main() -> None:
    try:
        print(count_awaiting(fetch_review_threads(sys.argv[1])))
    except Exception:
        # A status reader must never fail the hook that calls it.
        pass


if __name__ == "__main__":
    main()
