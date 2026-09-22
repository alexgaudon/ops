#!/usr/bin/env bash
#
# upgrade-node.sh — upgrade the Talos version of one node.
#
# This script changes the cluster. It is the only script of this skill that
# changes the cluster.
#
# The script needs the confirmation variable TALOS_UPGRADE_CONFIRM. Set the
# variable to the target version. This stops an accidental upgrade.
#
# Usage:
#   TALOS_UPGRADE_CONFIRM=<version> upgrade-node.sh <node-address> <version>
#
# Example:
#   TALOS_UPGRADE_CONFIRM=v1.13.10 upgrade-node.sh 10.0.0.40 v1.13.10
#
# Set DRY_RUN=1 to print the command without a change.
#
# Exit codes:
#   0  the node runs the target version
#   1  usage error, or the confirmation variable is absent
#   2  a safety check failed
#   3  the upgrade command failed
#   4  the node does not report the target version after the upgrade
#
set -euo pipefail

NODE="${1:-}"
TARGET_RAW="${2:-}"
if [ -z "$NODE" ] || [ -z "$TARGET_RAW" ]; then
  echo "Usage: TALOS_UPGRADE_CONFIRM=<version> $0 <node-address> <version>" >&2
  echo "Example: TALOS_UPGRADE_CONFIRM=v1.13.10 $0 10.0.0.40 v1.13.10" >&2
  exit 1
fi
TARGET="v${TARGET_RAW#v}"

EMPTY_SCHEMATIC="376567988ad370138ad8b2698212367b8edcb69b5fd68c80be1f2ec7d603b4ba"
SCHEMATIC="${TALOS_SCHEMATIC:-$EMPTY_SCHEMATIC}"
IMAGE="factory.talos.dev/metal-installer/$SCHEMATIC:$TARGET"
TIMEOUT="${TALOS_UPGRADE_TIMEOUT:-30m}"

if [ "${TALOS_UPGRADE_CONFIRM:-}" != "$TARGET" ]; then
  echo "upgrade-node: the confirmation variable is absent or different." >&2
  echo "upgrade-node: to upgrade node $NODE to $TARGET, run this command:" >&2
  echo >&2
  echo "  TALOS_UPGRADE_CONFIRM=$TARGET $0 $NODE $TARGET" >&2
  echo >&2
  exit 1
fi

MEMBERS=""
K8S=""
cleanup() {
  if [ -n "$MEMBERS" ]; then rm -f "$MEMBERS"; fi
  if [ -n "$K8S" ]; then rm -f "$K8S"; fi
}
trap cleanup EXIT

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
  echo "upgrade-node: cannot find an endpoint. Check the talosconfig." >&2
  exit 2
fi

MEMBERS="$(mktemp)"
if ! talosctl get members -o json -n "$ENDPOINT" >"$MEMBERS" 2>/dev/null || [ ! -s "$MEMBERS" ]; then
  echo "upgrade-node: cannot read the cluster members." >&2
  exit 2
fi

ROLE="$(jq -r --arg ip "$NODE" 'select((.spec.addresses | index($ip)) != null) | .spec.machineType' "$MEMBERS")"
NAME="$(jq -r --arg ip "$NODE" 'select((.spec.addresses | index($ip)) != null) | .spec.hostname' "$MEMBERS")"
NODE_VERSION="$(jq -r --arg ip "$NODE" 'select((.spec.addresses | index($ip)) != null) | (.spec.operatingSystem | capture("Talos \\((?<v>[^)]+)\\)").v)' "$MEMBERS")"

if [ -z "$ROLE" ] || [ -z "$NAME" ]; then
  echo "upgrade-node: the address $NODE is not a member of this cluster." >&2
  echo "upgrade-node: run scripts/list-nodes.sh to see the nodes." >&2
  exit 2
fi

echo "node:    $NAME ($NODE)"
echo "role:    $ROLE"
echo "current: $NODE_VERSION"
echo "target:  $TARGET"
echo "image:   $IMAGE"
echo

if [ "$NODE_VERSION" = "$TARGET" ]; then
  echo "upgrade-node: the node already runs $TARGET. No action."
  exit 0
fi

# Read the Kubernetes state once.
K8S="$(mktemp)"
if command -v kubectl >/dev/null 2>&1; then
  kubectl get nodes -o json >"$K8S" 2>/dev/null || : >"$K8S"
fi

# node_state <address> — print "ready<TAB>unschedulable" for the address.
node_state() {
  if [ ! -s "$K8S" ]; then
    printf '?\t?'
    return
  fi
  jq -r --arg ip "$1" \
    '.items[] | select(any(.status.addresses[]; .address == $ip)) | [(.status.conditions[] | select(.type == "Ready").status), ((.spec.unschedulable // false) | tostring)] | @tsv' \
    "$K8S"
}

# Safety check 1: this node must be ready and not cordoned.
STATE="$(node_state "$NODE")"
READY="${STATE%%	*}"
CORDONED="${STATE##*	}"
if [ "$READY" = "?" ]; then
  echo "upgrade-node: WARNING: no Kubernetes data. The ready check is not done." >&2
else
  if [ "$READY" != "True" ]; then
    echo "upgrade-node: the node is not ready (ready=$READY). Stop." >&2
    exit 2
  fi
  if [ "$CORDONED" != "false" ]; then
    echo "upgrade-node: the node is cordoned. Stop and inspect the cluster." >&2
    exit 2
  fi
fi

# Safety check 2: a control plane node needs the other control plane nodes.
if [ "$ROLE" = "controlplane" ]; then
  CPS="$(jq -r 'select(.spec.machineType == "controlplane") | .spec.addresses[0]' "$MEMBERS")"
  for other in $CPS; do
    if [ "$other" = "$NODE" ]; then
      continue
    fi
    OTHER_STATE="$(node_state "$other")"
    OTHER_READY="${OTHER_STATE%%	*}"
    OTHER_CORDONED="${OTHER_STATE##*	}"
    if [ "$OTHER_READY" = "?" ]; then
      continue
    fi
    if [ "$OTHER_READY" != "True" ] || [ "$OTHER_CORDONED" != "false" ]; then
      echo "upgrade-node: the control plane node $other is not ready (ready=$OTHER_READY cordoned=$OTHER_CORDONED)." >&2
      echo "upgrade-node: upgrade one control plane node at a time. Stop." >&2
      exit 2
    fi
  done
fi

if [ "${DRY_RUN:-}" = "1" ]; then
  echo "DRY_RUN: no change. The script would run this command:"
  echo
  echo "  talosctl upgrade -n $NODE --image $IMAGE --wait --timeout $TIMEOUT"
  echo
  exit 0
fi

echo "upgrade-node: starting the upgrade of $NAME ($NODE) to $TARGET."
echo "  talosctl upgrade -n $NODE --image $IMAGE --wait --timeout $TIMEOUT"
echo

if ! talosctl upgrade -n "$NODE" --image "$IMAGE" --wait --timeout "$TIMEOUT"; then
  echo >&2
  echo "upgrade-node: the upgrade command failed for $NAME ($NODE)." >&2
  echo "upgrade-node: the node uses the A-B image scheme. A failed boot returns to the old image." >&2
  exit 3
fi

echo
echo "upgrade-node: the upgrade command completed. Wait for the node."

if command -v kubectl >/dev/null 2>&1 && [ -s "$K8S" ]; then
  if kubectl wait --for=condition=Ready "node/$NAME" --timeout=10m >/dev/null 2>&1; then
    echo "upgrade-node: the Kubernetes node $NAME is ready."
  else
    echo "upgrade-node: the Kubernetes node $NAME is not ready after 10 minutes." >&2
  fi
fi

NEW_VERSION="$(talosctl version -n "$NODE" 2>/dev/null | awk '/^Server:/{ f = 1 } f && /Tag:/{ print $2; exit }')"
echo "upgrade-node: the node reports the version $NEW_VERSION."

if [ "$NEW_VERSION" != "$TARGET" ]; then
  echo "upgrade-node: the node does not report the target version $TARGET." >&2
  exit 4
fi

if [ "$ROLE" = "controlplane" ]; then
  echo "upgrade-node: check etcd before the next node:"
  echo "  talosctl -n $NODE etcd status"
fi

echo "upgrade-node: done. The node $NAME ($NODE) runs $TARGET."
