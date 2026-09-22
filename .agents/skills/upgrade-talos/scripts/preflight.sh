#!/usr/bin/env bash
#
# preflight.sh — check that the cluster can safely start a Talos upgrade.
#
# This script is read-only. It never changes the cluster.
#
# Usage:
#   preflight.sh <target-version>        example: preflight.sh v1.14.1
#
# Exit codes:
#   0  all checks pass
#   1  usage error
#   2  one or more checks failed
#
set -euo pipefail

TARGET_RAW="${1:-}"
if [ -z "$TARGET_RAW" ]; then
  echo "Usage: $0 <target-version>    example: $0 v1.14.1" >&2
  exit 1
fi
TARGET="v${TARGET_RAW#v}"

EMPTY_SCHEMATIC="376567988ad370138ad8b2698212367b8edcb69b5fd68c80be1f2ec7d603b4ba"
SCHEMATIC="${TALOS_SCHEMATIC:-$EMPTY_SCHEMATIC}"
FACTORY="${TALOS_FACTORY:-https://factory.talos.dev}"

FAILED=0
pass() { printf 'PASS  %s\n' "$*"; }
warn() { printf 'WARN  %s\n' "$*"; }
fail() {
  printf 'FAIL  %s\n' "$*"
  FAILED=$((FAILED + 1))
}

strip_v() { printf '%s' "${1#v}"; }

# v_ge A B — true when version A is equal to version B or newer than version B.
v_ge() {
  [ "$(printf '%s\n%s\n' "$(strip_v "$2")" "$(strip_v "$1")" | sort -V | tail -n 1)" = "$(strip_v "$1")" ]
}

# minor_num v1.13.10 — print 113.
minor_num() { printf '%s' "$(strip_v "$1")" | awk -F. '{ print $1 * 100 + $2 }'; }

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

MEMBERS=""
K8S=""
HEALTH=""
cleanup() {
  if [ -n "$MEMBERS" ]; then rm -f "$MEMBERS"; fi
  if [ -n "$K8S" ]; then rm -f "$K8S"; fi
  if [ -n "$HEALTH" ]; then rm -f "$HEALTH"; fi
}
trap cleanup EXIT

echo "== Talos upgrade preflight =="
echo "target version: $TARGET"
echo "schematic:      $SCHEMATIC"
echo

# 1. The client.
CLIENT=""
if command -v talosctl >/dev/null 2>&1; then
  CLIENT="$(talosctl version --client 2>/dev/null | awk '/Tag:/{ print $2; exit }')"
  pass "talosctl is installed (client $CLIENT)"
  if v_ge "$CLIENT" "$TARGET"; then
    pass "the client version $CLIENT is equal to the target or newer"
  else
    warn "the client version $CLIENT is older than the target $TARGET. Install talosctl $TARGET."
  fi
else
  fail "talosctl is not on the PATH"
  echo
  echo "preflight: cannot continue without talosctl" >&2
  exit 2
fi

# 2. The client certificate.
TALOSCONFIG_PATH="${TALOSCONFIG:-$HOME/.talos/config}"
if [ -r "$TALOSCONFIG_PATH" ]; then
  CRT="$(awk '/^[[:space:]]*crt:[[:space:]]*/{ sub(/^[[:space:]]*crt:[[:space:]]*/, ""); print; exit }' "$TALOSCONFIG_PATH")"
  if [ -z "$CRT" ]; then
    fail "cannot read the client certificate from $TALOSCONFIG_PATH"
  elif printf '%s' "$CRT" | openssl enc -base64 -d -A 2>/dev/null | openssl x509 -noout -checkend 86400 >/dev/null 2>&1; then
    pass "the client certificate in $TALOSCONFIG_PATH is valid for more than one day"
  else
    fail "the client certificate in $TALOSCONFIG_PATH is expired or expires in less than one day"
    echo "      Run: make -C terraform fetch-talosconfig"
  fi
else
  fail "no readable talosconfig at $TALOSCONFIG_PATH"
fi

# 3. The cluster.
RESOLVED_ENDPOINT="$(resolve_endpoint)"
if [ -z "$RESOLVED_ENDPOINT" ]; then
  fail "cannot find an endpoint. Check the talosconfig."
  echo
  echo "preflight: $FAILED check(s) failed. Do not start the upgrade."
  exit 2
fi

MEMBERS="$(mktemp)"
if talosctl get members -o json -n "$RESOLVED_ENDPOINT" >"$MEMBERS" 2>/dev/null && [ -s "$MEMBERS" ]; then
  pass "the cluster answers"
else
  fail "the cluster does not answer. Check the certificate and the network."
  echo
  echo "preflight: $FAILED check(s) failed. Do not start the upgrade."
  exit 2
fi

CPS="$(jq -r 'select(.spec.machineType == "controlplane") | .spec.addresses[0]' "$MEMBERS" | sort -V)"
WORKERS="$(jq -r 'select(.spec.machineType == "worker") | .spec.addresses[0]' "$MEMBERS" | sort -V)"
ALL_NODES="$(printf '%s\n%s\n' "$CPS" "$WORKERS" | grep -v '^$')"

ENDPOINT="$(printf '%s\n' "$CPS" | head -n 1)"
if [ -z "$ENDPOINT" ]; then
  ENDPOINT="$RESOLVED_ENDPOINT"
fi

# 4. The version of each node.
# A step can be partly done: some nodes run the target version and the rest
# run the old version. This is the normal state inside a step. The check
# fails when the nodes report more than two versions, or when no node runs
# the target version.
CURRENT=""
VERSIONS_SEEN="$(jq -r '.spec.operatingSystem | capture("Talos \\((?<v>[^)]+)\\)").v' "$MEMBERS" | sort -u -V)"
VERSION_COUNT="$(printf '%s\n' "$VERSIONS_SEEN" | grep -c . || true)"
NODE_TOTAL="$(jq -r '.spec.hostname' "$MEMBERS" | grep -c . || true)"
TARGET_NODES="$(jq -r --arg t "$TARGET" 'select((.spec.operatingSystem | capture("Talos \\((?<v>[^)]+)\\)").v) == $t) | .spec.hostname' "$MEMBERS" | grep -c . || true)"

if [ "$VERSION_COUNT" -eq 1 ]; then
  CURRENT="$VERSIONS_SEEN"
  if [ "$CURRENT" = "$TARGET" ]; then
    pass "every node already runs the target version $TARGET"
    echo "      The step is complete. Run: scripts/verify.sh $TARGET"
  else
    pass "every node reports the same Talos version ($CURRENT)"
  fi
elif [ "$VERSION_COUNT" -eq 2 ] && [ "$TARGET_NODES" -gt 0 ]; then
  CURRENT="$(printf '%s\n' "$VERSIONS_SEEN" | grep -v -x -F "$TARGET" | head -n 1)"
  OLD_NODES=$((NODE_TOTAL - TARGET_NODES))
  pass "the step to $TARGET is partly done: $TARGET_NODES node(s) run $TARGET, $OLD_NODES node(s) run $CURRENT"
  echo "      This is the normal state inside a step. Continue with the nodes that run $CURRENT."
else
  fail "the nodes report $VERSION_COUNT different Talos versions:"
  printf '%s\n' "$VERSIONS_SEEN" | sed 's/^/      /'
  echo "      No node runs the target version $TARGET, or several steps are mixed."
  echo "      Stop and inspect the cluster."
fi

# 5. and 6. The Kubernetes state.
K8S="$(mktemp)"
if command -v kubectl >/dev/null 2>&1 && kubectl get nodes -o json >"$K8S" 2>/dev/null && [ -s "$K8S" ]; then
  CORDONED="$(jq -r '[.items[] | select(.spec.unschedulable == true) | .metadata.name] | join(", ")' "$K8S")"
  NOT_READY="$(jq -r '[.items[] | select((.status.conditions[] | select(.type == "Ready").status) != "True") | .metadata.name] | join(", ")' "$K8S")"
  if [ -z "$CORDONED" ]; then
    pass "no Kubernetes node is cordoned"
  else
    fail "cordoned node(s): $CORDONED"
    echo "      A cordon shows a running upgrade. Stop and inspect the cluster."
  fi
  if [ -z "$NOT_READY" ]; then
    pass "every Kubernetes node is ready"
  else
    fail "node(s) not ready: $NOT_READY"
  fi
else
  warn "kubectl is not available. The cordon check and the ready check are not done."
fi

# 7. The etcd health.
if [ -n "$ENDPOINT" ]; then
  HEALTH="$(mktemp)"
  if talosctl health -n "$ENDPOINT" --wait-timeout 60s >"$HEALTH" 2>&1; then
    pass "talosctl health reports a healthy cluster"
  else
    fail "talosctl health reports a problem"
    tail -n 5 "$HEALTH" | sed 's/^/      /'
  fi
else
  fail "no endpoint for the health check"
fi

# 8. The target version in the Image Factory.
FACTORY_VERSIONS="$(curl -fsS --max-time 20 "$FACTORY/versions" 2>/dev/null || true)"
if [ -z "$FACTORY_VERSIONS" ]; then
  warn "cannot read the Image Factory version list. Check the network."
elif printf '%s' "$FACTORY_VERSIONS" | jq -e --arg v "$TARGET" 'index($v) != null' >/dev/null 2>&1; then
  pass "the Image Factory offers the version $TARGET"
else
  fail "the Image Factory does not offer the version $TARGET"
fi

# 9. The upgrade distance.
# CURRENT is the version of the nodes that are not upgraded yet.
if [ -n "$CURRENT" ]; then
  CURRENT_MINOR="$(minor_num "$CURRENT")"
  TARGET_MINOR="$(minor_num "$TARGET")"
  if [ "$TARGET_MINOR" -lt "$CURRENT_MINOR" ]; then
    fail "the target $TARGET is older than the current version $CURRENT. Do not downgrade."
  elif [ "$TARGET_MINOR" -eq "$CURRENT_MINOR" ]; then
    if [ "$(strip_v "$TARGET")" = "$(strip_v "$CURRENT")" ]; then
      fail "every node already runs $TARGET"
    else
      pass "the target is a patch update of the current minor version"
    fi
  elif [ "$TARGET_MINOR" -eq $((CURRENT_MINOR + 1)) ]; then
    pass "the target is the adjacent minor version of $CURRENT"
  else
    fail "the target $TARGET skips a minor version from $CURRENT"
    echo "      Upgrade one minor version at a time."
    echo "      Run: scripts/plan-upgrade.sh $TARGET"
  fi
fi

# 10. The system extensions and the schematic of the nodes.
EXT_TOTAL=0
NODE_SCHEMATICS=""
for ip in $ALL_NODES; do
  EXT_TABLE="$(talosctl get extensions -n "$ip" 2>/dev/null | tail -n +2 || true)"
  # The node reports the schematic it was installed from in a row with the
  # name "schematic". Every other row is a system extension.
  SCHEMATIC_ROW="$(printf '%s\n' "$EXT_TABLE" | awk '$6 == "schematic" { print $7; exit }')"
  if [ -n "$SCHEMATIC_ROW" ]; then
    NODE_SCHEMATICS="$NODE_SCHEMATICS $SCHEMATIC_ROW"
  fi
  COUNT="$(printf '%s\n' "$EXT_TABLE" | awk 'NF > 0 && $6 != "" && $6 != "schematic" { print $6 }' | grep -c . || true)"
  EXT_TOTAL=$((EXT_TOTAL + COUNT))
done

if [ "${EXT_TOTAL:-0}" -eq 0 ]; then
  pass "the nodes report no system extensions"
else
  fail "the nodes report $EXT_TOTAL system extensions"
  echo "      Set TALOS_SCHEMATIC to the schematic that carries the system extensions."
fi

if [ -n "$NODE_SCHEMATICS" ]; then
  UNIQUE_SCHEMATICS="$(printf '%s\n' $NODE_SCHEMATICS | sort -u)"
  SCHEMATIC_COUNT="$(printf '%s\n' "$UNIQUE_SCHEMATICS" | grep -c . || true)"
  if [ "$SCHEMATIC_COUNT" -eq 1 ]; then
    pass "the nodes report the schematic $UNIQUE_SCHEMATICS"
    if [ "$UNIQUE_SCHEMATICS" = "$SCHEMATIC" ]; then
      pass "the image schematic matches the schematic of the nodes"
    else
      fail "the image schematic $SCHEMATIC is different from the schematic of the nodes $UNIQUE_SCHEMATICS"
    fi
  else
    warn "the nodes report different schematics:"
    printf '%s\n' "$UNIQUE_SCHEMATICS" | sed 's/^/      /'
  fi
else
  warn "the nodes do not report a schematic. Confirm the schematic by hand."
fi

if curl -fsS --max-time 20 "$FACTORY/schematics/$SCHEMATIC" 2>/dev/null | grep -q 'customization: {}'; then
  pass "the schematic $SCHEMATIC carries no customization"
else
  warn "cannot confirm that the schematic $SCHEMATIC is empty. Confirm the schematic by hand."
fi

echo
if [ "$FAILED" -eq 0 ]; then
  echo "preflight: all checks pass. The cluster can start an upgrade to $TARGET."
  exit 0
fi

echo "preflight: $FAILED check(s) failed. Do not start the upgrade."
exit 2
