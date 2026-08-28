#!/usr/bin/env bash
#
# classify-versions.sh — report version bumps in a pull request.
#
# This script reads a pull request diff, extracts old and new dependency
# versions, and classifies each transition as major, minor, or patch.
# It is a helper for the evaluate-prs skill. The agent makes the final
# breaking-change judgment.
#
# Usage:
#   classify-versions.sh <pr-number>          human-readable output
#   classify-versions.sh <pr-number> --json   machine-readable output
#
# Exit codes:
#   0  PR analyzed (may contain 0 version bumps)
#   1  usage error
#   2  PR not found or diff could not be retrieved
#
set -euo pipefail

PR="${1:-}"
MODE="${2:-text}"

if [[ -z "$PR" ]]; then
  echo "Usage: $0 <pr-number> [--json]" >&2
  exit 1
fi

# classify returns major/minor/patch for two version strings.
classify() {
  local old="$1" new="$2"
  old="${old#v}"   # strip a leading v
  new="${new#v}"
  local o0 o1 o2 n0 n1 n2
  IFS='.' read -r o0 o1 o2 <<< "$old"
  IFS='.' read -r n0 n1 n2 <<< "$new"
  o1="${o1:-0}"; o2="${o2:-0}"
  n1="${n1:-0}"; n2="${n2:-0}"
  if [[ "$o0" != "$n0" ]]; then echo "major"; return; fi
  if [[ "$o1" != "$n1" ]]; then echo "minor"; return; fi
  if [[ "$o2" != "$n2" ]]; then echo "patch"; return; fi
  echo "none"
}

# Get the diff for the PR. If this fails, exit with 2.
diff_body="$(gh pr diff "$PR")" || { echo "Unable to read PR #$PR diff" >&2; exit 2; }

# Extract removed (-) and added (+) version values, in order of appearance.
old_str="$(printf '%s\n' "$diff_body" \
  | grep -E '^-[^-]' \
  | grep -E 'version[[:space:]]*=[[:space:]]*"[^"]+"' \
  | sed -E 's/.*"([^"]+)".*/\1/' \
  | grep -E '^v?[0-9]+([.][0-9]+)+$' )"

new_str="$(printf '%s\n' "$diff_body" \
  | grep -E '^\+[^+]' \
  | grep -E 'version[[:space:]]*=[[:space:]]*"[^"]+"' \
  | sed -E 's/.*"([^"]+)".*/\1/' \
  | grep -E '^v?[0-9]+([.][0-9]+)+$' )"

olds=()
news=()
while IFS= read -r line; do olds+=("$line"); done <<< "$old_str"
while IFS= read -r line; do news+=("$line"); done <<< "$new_str"

if [[ "${#olds[@]}" -eq 0 && "${#news[@]}" -eq 0 ]]; then
  if [[ "$MODE" == "--json" ]]; then
    echo '[]'
  else
    echo "PR #$PR: no version bumps detected"
  fi
  exit 0
fi

if [[ "${#olds[@]}" -ne "${#news[@]}" ]]; then
  echo "warning: unmatched old/new version counts for PR #$PR" >&2
fi

count="${#olds[@]}"
if (( "${#news[@]}" > "${#olds[@]}" )); then count="${#news[@]}"; fi  # guard against index overflow

declare -a results=()
top="patch"

for (( i = 0; i < count; i++ )); do
  old_v="${olds[$i]:-?}"
  new_v="${news[$i]:-?}"
  cls="$(classify "$old_v" "$new_v")"
  results+=("$cls|$old_v|$new_v")
  # Highest severity wins for the summary.
  case "$cls" in
    major) top="major" ;;
    minor) [[ "$top" != "major" ]] && top="minor" ;;
  esac
done

if [[ "$MODE" == "--json" ]]; then
  jq -n \
    --arg pr "$PR" \
    --arg top "$top" \
    --argjson bumps "$(printf '%s\n' "${results[@]}" | jq -R -s 'split("\n") | map(select(length > 0)) | map(split("|") | {class: .[0], old: .[1], new: .[2]})')" \
    '{pr: ($pr | tonumber), verdict: $top, bumps: $bumps}'
else
  echo "PR #$PR verdict: $top"
  for r in "${results[@]}"; do
    IFS='|' read -r cls old_v new_v <<< "$r"
    printf '  %-6s %s -> %s\n' "$cls" "$old_v" "$new_v"
  done
fi
