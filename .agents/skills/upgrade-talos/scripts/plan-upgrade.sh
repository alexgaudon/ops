#!/usr/bin/env bash
#
# plan-upgrade.sh — build the ordered Talos upgrade plan.
#
# The script prints one step for each minor version between the current
# version and the target version. Each step gives the image and the command
# for each node.
#
# This script is read-only. It never changes the cluster.
#
# Usage:
#   plan-upgrade.sh <target-version>      example: plan-upgrade.sh v1.14.1
#
# Exit codes:
#   0  plan printed
#   1  usage error
#   2  the cluster does not answer, or the versions are not clear
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

strip_v() { printf '%s' "${1#v}"; }
minor_num() { printf '%s' "$(strip_v "$1")" | awk -F. '{ print $1 * 100 + $2 }'; }
minor_of() { printf '%s' "$(strip_v "$1")" | awk -F. '{ print $1 "." $2 }'; }

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
  echo "plan-upgrade: cannot find an endpoint. Check the talosconfig." >&2
  exit 2
fi

MEMBERS=""
cleanup() { if [ -n "$MEMBERS" ]; then rm -f "$MEMBERS"; fi; }
trap cleanup EXIT

MEMBERS="$(mktemp)"
if ! talosctl get members -o json -n "$ENDPOINT" >"$MEMBERS" 2>/dev/null || [ ! -s "$MEMBERS" ]; then
  echo "plan-upgrade: cannot read the cluster members." >&2
  exit 2
fi

CPS="$(jq -r 'select(.spec.machineType == "controlplane") | .spec.addresses[0]' "$MEMBERS" | sort -V)"
WORKERS="$(jq -r 'select(.spec.machineType == "worker") | .spec.addresses[0]' "$MEMBERS" | sort -V)"

VERSIONS_SEEN="$(jq -r '.spec.operatingSystem | capture("Talos \\((?<v>[^)]+)\\)").v' "$MEMBERS" | sort -u -V)"
VERSION_COUNT="$(printf '%s\n' "$VERSIONS_SEEN" | grep -c . || true)"
TARGET_NODES="$(jq -r --arg t "$TARGET" 'select((.spec.operatingSystem | capture("Talos \\((?<v>[^)]+)\\)").v) == $t) | .spec.hostname' "$MEMBERS" | grep -c . || true)"

if [ "$VERSION_COUNT" -eq 1 ]; then
  CURRENT="$VERSIONS_SEEN"
elif [ "$VERSION_COUNT" -eq 2 ] && [ "$TARGET_NODES" -gt 0 ]; then
  # A step is partly done. The plan starts from the nodes that are not
  # upgraded yet.
  CURRENT="$(printf '%s\n' "$VERSIONS_SEEN" | grep -v -x -F "$TARGET" | head -n 1)"
  echo "Note: the step to $TARGET is partly done. The plan starts from $CURRENT."
  echo
else
  echo "plan-upgrade: the nodes report $VERSION_COUNT different Talos versions:" >&2
  printf '  %s\n' "$VERSIONS_SEEN" >&2
  echo "plan-upgrade: no node runs the target version $TARGET, or several steps are mixed." >&2
  echo "plan-upgrade: stop and inspect the cluster." >&2
  exit 2
fi

FACTORY_VERSIONS="$(curl -fsS --max-time 20 "$FACTORY/versions" 2>/dev/null || true)"

# latest_patch 1.13 — print the newest v1.13.x that the factory offers.
latest_patch() {
  if [ -z "$FACTORY_VERSIONS" ]; then
    return 1
  fi
  printf '%s' "$FACTORY_VERSIONS" \
    | jq -r --arg p "v$1." '.[] | select(startswith($p))' \
    | sort -V | tail -n 1
}

CURRENT_MINOR="$(minor_num "$CURRENT")"
TARGET_MINOR="$(minor_num "$TARGET")"

echo "== Talos upgrade plan =="
echo "current version: $CURRENT"
echo "target version:  $TARGET"
echo "schematic:       $SCHEMATIC"
echo "control planes:  $(printf '%s' "$CPS" | tr '\n' ' ')"
echo "workers:         $(printf '%s' "$WORKERS" | tr '\n' ' ')"
echo

if [ "$TARGET_MINOR" -lt "$CURRENT_MINOR" ]; then
  echo "plan-upgrade: the target is older than the current version. Do not downgrade." >&2
  exit 2
fi

if [ "$TARGET_MINOR" -eq "$CURRENT_MINOR" ]; then
  echo "The target is a patch update of the current minor version."
  STOPS="$TARGET"
else
  if [ "$TARGET_MINOR" -gt $((CURRENT_MINOR + 1)) ]; then
    echo "Note: the target skips a minor version. The plan gives every intermediate step."
    echo
  fi
  STOPS="$(awk -v cur="$CURRENT_MINOR" -v tgt="$TARGET_MINOR" 'BEGIN { for (m = cur; m <= tgt; m++) print m }')"
fi

STEP=0
for m in $STOPS; do
  if [ "$TARGET_MINOR" -eq "$CURRENT_MINOR" ]; then
    VERSION="$TARGET"
  else
    MINOR="$(printf '%s' "$m" | awk '{ printf "%d.%d", int($1 / 100), $1 % 100 }')"
    if [ "$m" -eq "$TARGET_MINOR" ]; then
      VERSION="$TARGET"
    else
      VERSION="$(latest_patch "$MINOR" || true)"
      if [ -z "$VERSION" ]; then
        echo "plan-upgrade: cannot find the latest patch of the minor version $MINOR." >&2
        echo "plan-upgrade: check the network, or give the target version of that step." >&2
        exit 2
      fi
    fi
  fi

  if [ "$(strip_v "$VERSION")" = "$(strip_v "$CURRENT")" ]; then
    echo "Skip $VERSION: every node already runs this version."
    echo
    continue
  fi

  STEP=$((STEP + 1))
  IMAGE="factory.talos.dev/metal-installer/$SCHEMATIC:$VERSION"

  echo "Step $STEP: upgrade to $VERSION"
  echo "  image: $IMAGE"
  echo "  Control plane nodes. Do one node at a time:"
  for ip in $CPS; do
    echo "    TALOS_UPGRADE_CONFIRM=$VERSION scripts/upgrade-node.sh $ip $VERSION"
    echo "    scripts/verify.sh $VERSION --in-progress"
  done
  echo "  Worker nodes. Do one node after the other:"
  for ip in $WORKERS; do
    echo "    TALOS_UPGRADE_CONFIRM=$VERSION scripts/upgrade-node.sh $ip $VERSION"
  done
  echo "  Verification after the step:"
  echo "    scripts/verify.sh $VERSION"
  echo "  Raw command for one node:"
  echo "    talosctl upgrade -n <node-address> --image $IMAGE --wait"
  echo
done

echo "After the last step, apply the OpenTofu change:"
echo "  tofu -chdir=terraform plan"
echo "  tofu -chdir=terraform apply"
