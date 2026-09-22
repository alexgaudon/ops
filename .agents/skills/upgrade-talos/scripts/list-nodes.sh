#!/usr/bin/env bash
#
# list-nodes.sh — print the Talos node inventory of this cluster.
#
# Output: one tab-separated line per node with the role, the hostname, the
# address, the Talos version, the Kubernetes ready state, and the cordon
# state. The first line is a header.
#
# The Talos data comes from the cluster (talosctl get members).
# The Kubernetes data comes from kubectl. The value is "?" when kubectl is
# not available.
#
# Usage:
#   list-nodes.sh
#
# Exit codes:
#   0  inventory printed
#   2  the cluster does not answer
#
set -euo pipefail

# resolve_endpoint — print the first endpoint from the talosconfig.
# The talosconfig of this homelab sets the endpoints and no nodes. Every
# command that touches a node needs an explicit node argument.
resolve_endpoint() {
  if [ -n "${TALOS_ENDPOINT:-}" ]; then
    printf '%s' "$TALOS_ENDPOINT"
    return 0
  fi
  talosctl config info 2>/dev/null \
    | awk '/^Endpoints:/{ sub(/^Endpoints:[[:space:]]*/, ""); split($0, a, ","); gsub(/[[:space:]]/, "", a[1]); print a[1]; exit }'
}

ENDPOINT="$(resolve_endpoint)"
if [ -z "$ENDPOINT" ]; then
  echo "list-nodes: cannot find an endpoint. Check the talosconfig." >&2
  exit 2
fi

MEMBERS="$(mktemp)"
K8S="$(mktemp)"
trap 'rm -f "$MEMBERS" "$K8S"' EXIT

if ! talosctl get members -o json -n "$ENDPOINT" >"$MEMBERS" 2>/dev/null; then
  echo "list-nodes: cannot read the cluster members." >&2
  echo "list-nodes: check the talosconfig with 'talosctl config info'." >&2
  exit 2
fi

if [ ! -s "$MEMBERS" ]; then
  echo "list-nodes: the cluster returned no members. Is the cluster up?" >&2
  exit 2
fi

if command -v kubectl >/dev/null 2>&1; then
  kubectl get nodes -o json 2>/dev/null \
    | jq -r '.items[] | [.metadata.name, (.status.conditions[] | select(.type == "Ready").status), ((.spec.unschedulable // false) | tostring)] | @tsv' \
    >"$K8S" 2>/dev/null || : >"$K8S"
fi

printf 'ROLE\tHOSTNAME\tADDRESS\tTALOS\tK8S-READY\tCORDONED\n'

jq -r '[.spec.machineType, .spec.hostname, (.spec.addresses | join(",")), (.spec.operatingSystem | capture("Talos \\((?<v>[^)]+)\\)").v)] | @tsv' "$MEMBERS" \
  | sort -k1,1 -k3,3V \
  | while IFS='	' read -r role name addr ver; do
      ready="?"
      cordoned="?"
      if [ -s "$K8S" ]; then
        ready="$(awk -F'\t' -v n="$name" '$1 == n { print $2 }' "$K8S")"
        cordoned="$(awk -F'\t' -v n="$name" '$1 == n { print $3 }' "$K8S")"
        [ -n "$ready" ] || ready="?"
        [ -n "$cordoned" ] || cordoned="?"
      fi

      # Show the ready state in a short form.
      case "$ready" in
        True) ready="yes" ;;
        False) ready="NO" ;;
      esac

      printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$role" "$name" "$addr" "$ver" "$ready" "$cordoned"
    done
