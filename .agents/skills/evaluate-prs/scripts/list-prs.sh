#!/usr/bin/env bash
#
# list-prs.sh — list open pull requests in the current repository.
#
# Output: one tab-separated line per PR with number, title, head branch,
# draft state, and mergeability. Use this on its own, or pipe the numbers
# into classify-versions.sh.
#
# Usage:
#   list-prs.sh              all open PRs in HEAD branch base
#   list-prs.sh main         PRs targeting the main branch (default)
#
set -euo pipefail

BASE="${1:-main}"

gh pr list \
  --state open \
  --base "$BASE" \
  --json number,title,headRefName,isDraft,mergeable,updatedAt \
  --jq 'sort_by(.number) | .[] | [.number, .title, .headRefName, (if .isDraft then "DRAFT" else "OPEN" end), .mergeable, .updatedAt] | @tsv'
