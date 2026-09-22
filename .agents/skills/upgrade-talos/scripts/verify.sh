#!/usr/bin/env bash
#
# verify.sh — check the cluster after an upgrade step.
#
# This script is read-only. It never changes the cluster.
#
# Usage:
#   verify.sh <expected-version>                 strict: every node
#   verify.sh <expected-version> --in-progress   allow the nodes that are
#                                                not upgraded yet
#
# Use the strict form after the last node of a step. Use the --in-progress
# form between the nodes of a step. The --in-progress form reports a node
# that runs the old version as a WARN, not as a failure. Every other check
# stays the same.
#
# Exit codes:
#   0  every check passes
#   1  usage error
#   2  one or more checks failed
#
set -euo pipefail

TARGET_RAW="${1:-}"
if [ -z "$TARGET_RAW" ]; then
  echo "Usage: $0 <expected-version> [--in-progress]    example: $0 v1.14.1" >&2
  exit 1
fi
TARGET="v${TARGET_RAW#v}"

IN_PROGRESS=0
if [ "${2:-}" = "--in-progress" ]; then
  IN_PROGRESS=1
fi

FAILED=0
pass() { printf 'PASS  %s\n' "$*"; }
warn() { printf 'WARN  %s\n' "$*"; }
fail() {
  printf 'FAIL  %s\n' "$*"
  FAILED=$((FAILED + 1))
}

MEMBERS=""
K8S=""
HEALTH=""
cleanup() {
  if [ -n "$MEMBERS" ]; then rm -f "$MEMBERS"; fi
  if [ -n "$K8S" ]; then rm -f "$K8S"; fi
  if [ -n "$HEALTH" ]; then rm -f "$HEALTH"; fi
}
trap cleanup EXIT

echo "== Talos upgrade verification (expected version $TARGET) =="
echo

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

RESOLVED_ENDPOINT="$(resolve_endpoint)"
if [ -z "$RESOLVED_ENDPOINT" ]; then
  echo "verify: cannot find an endpoint. Check the talosconfig." >&2
  exit 2
fi

MEMBERS="$(mktemp)"
if ! talosctl get members -o json -n "$RESOLVED_ENDPOINT" >"$MEMBERS" 2>/dev/null || [ ! -s "$MEMBERS" ]; then
  echo "verify: cannot read the cluster members." >&2
  exit 2
fi

# 1. The version of each node.
# The old version is the single version that is not the target version.
OLD_VERSION="$(jq -r '.spec.operatingSystem | capture("Talos \\((?<v>[^)]+)\\)").v' "$MEMBERS" | sort -u -V | grep -v -x -F "$TARGET" | head -n 1 || true)"
NOT_UPGRADED=0

while IFS='	' read -r role name ver; do
  if [ "$ver" = "$TARGET" ]; then
    pass "$name ($role) runs $ver"
  elif [ "$IN_PROGRESS" -eq 1 ] && [ -n "$OLD_VERSION" ] && [ "$ver" = "$OLD_VERSION" ]; then
    warn "$name ($role) runs $ver (not upgraded yet)"
    NOT_UPGRADED=$((NOT_UPGRADED + 1))
  else
    fail "$name ($role) runs $ver, not $TARGET"
    NOT_UPGRADED=$((NOT_UPGRADED + 1))
  fi
done <<EOF
$(jq -r '[.spec.machineType, .spec.hostname, (.spec.operatingSystem | capture("Talos \\((?<v>[^)]+)\\)").v)] | @tsv' "$MEMBERS" | sort -k1,1 -k2,2)
EOF

# 2. The Kubernetes state.
K8S="$(mktemp)"
if command -v kubectl >/dev/null 2>&1 && kubectl get nodes -o json >"$K8S" 2>/dev/null && [ -s "$K8S" ]; then
  CORDONED="$(jq -r '[.items[] | select(.spec.unschedulable == true) | .metadata.name] | join(", ")' "$K8S")"
  NOT_READY="$(jq -r '[.items[] | select((.status.conditions[] | select(.type == "Ready").status) != "True") | .metadata.name] | join(", ")' "$K8S")"
  if [ -z "$NOT_READY" ]; then
    pass "every Kubernetes node is ready"
  else
    fail "node(s) not ready: $NOT_READY"
  fi
  if [ -z "$CORDONED" ]; then
    pass "no Kubernetes node is cordoned"
  else
    fail "cordoned node(s): $CORDONED"
  fi
  K8S_VERSION="$(jq -r '[.items[].status.nodeInfo.kubeletVersion] | unique | join(", ")' "$K8S")"
  echo "      Kubernetes version: $K8S_VERSION"
else
  warn "kubectl is not available. The Kubernetes checks are not done."
fi

# 3. The cluster health.
ENDPOINT="${TALOS_ENDPOINT:-$(jq -r 'select(.spec.machineType == "controlplane") | .spec.addresses[0]' "$MEMBERS" | sort -V | head -n 1)}"
if [ -z "$ENDPOINT" ]; then
  ENDPOINT="$RESOLVED_ENDPOINT"
fi
HEALTH="$(mktemp)"
if [ -n "$ENDPOINT" ] && talosctl health -n "$ENDPOINT" --wait-timeout 120s >"$HEALTH" 2>&1; then
  pass "talosctl health reports a healthy cluster"
else
  fail "talosctl health reports a problem"
  tail -n 5 "$HEALTH" | sed 's/^/      /'
fi

# 4. The workload controller.
if command -v flux >/dev/null 2>&1; then
  FLUX_TABLE="$(flux get kustomizations -A 2>/dev/null || true)"
  READY_COL="$(printf '%s\n' "$FLUX_TABLE" | head -n 1 | awk '{ for (i = 1; i <= NF; i++) if ($i == "READY") print i }')"
  if [ -n "$READY_COL" ]; then
    KUSTOMIZATION_COUNT="$(printf '%s\n' "$FLUX_TABLE" | tail -n +2 | grep -c . || true)"
    UNREADY="$(printf '%s\n' "$FLUX_TABLE" | tail -n +2 | awk -v c="$READY_COL" '$c != "True" { print $2 }' | tr '\n' ' ')"
    if [ -z "$UNREADY" ]; then
      pass "every Flux kustomization is ready ($KUSTOMIZATION_COUNT)"
    else
      fail "Flux kustomization(s) not ready: $UNREADY"
      echo "      Run: flux get kustomizations -A"
    fi
  else
    warn "cannot read the Flux state with the flux command"
  fi
else
  warn "the flux command is not available. The Flux check is not done."
fi

echo
if [ "$FAILED" -eq 0 ]; then
  if [ "$IN_PROGRESS" -eq 1 ] && [ "$NOT_UPGRADED" -gt 0 ]; then
    echo "verify: every check passes. The step to $TARGET continues: $NOT_UPGRADED node(s) remain."
  else
    echo "verify: every check passes. The cluster runs $TARGET."
  fi
  exit 0
fi

echo "verify: $FAILED check(s) failed. Inspect the cluster before the next node."
exit 2
