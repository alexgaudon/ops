---
name: upgrade-talos
description: >
  Plans, checks, and runs a Talos Linux operating system upgrade of the
  Kubernetes nodes in this homelab. The skill moves the nodes forward one
  minor version at a time and gates every node on cluster health. Use it to
  upgrade the Talos version of the nodes. Do not use it to change Kubernetes,
  to change the OpenTofu resources, or to rotate the cluster secrets.
---

# Upgrade Talos

Upgrade the Talos nodes of this homelab. Move the nodes forward one minor
version at a time. Check the cluster health before each node and after each
node.

## Scope

This repository is a homelab. Six Talos nodes carry the Kubernetes cluster.
Three nodes are control planes. Three nodes are workers.

Flux and OpenTofu do not upgrade a Talos node. Only the command
`talosctl upgrade` upgrades a node.

The OpenTofu apply changes the wanted machine configuration. The OpenTofu
apply does not upgrade an installed node. The Talos documentation says that
the `.machine.install` field has an effect only at install time and at
upgrade time.

This skill does not change the Kubernetes version. This skill does not change
the OpenTofu resources. This skill does not change the cluster secrets.

## Prerequisites

Check these items before you start.

- `talosctl` must be on the PATH.
- The version of `talosctl` must be equal to the target version or newer.
- The talosconfig must hold a client certificate that is not expired.
  Run `make -C terraform fetch-talosconfig` when the certificate is expired.
- The kubeconfig must work. The command `kubectl get nodes` must answer.
- The machine that runs the upgrade must reach the Image Factory.

Stop and report when a prerequisite fails.

## Definitions

- **Adjacent minor**: the next minor version. Version v1.13 is adjacent to
  version v1.12.
- **Upgrade step**: one `talosctl upgrade` command for one node.
- **Empty schematic**: the Talos Image Factory schematic that carries no
  customization. The identifier is
  `376567988ad370138ad8b2698212367b8edcb69b5fd68c80be1f2ec7d603b4ba`.
  Use the empty schematic when the nodes have no system extensions.
- **Image**: the container image for an upgrade. The name has this form:
  `factory.talos.dev/metal-installer/<schematic>:<version>`.
  Starting with Talos 1.14, the image `ghcr.io/siderolabs/installer` is not
  published. Use the Image Factory image.
- **Contract**: the `talos_version` argument of the
  `data.talos_machine_configuration` data source. The contract sets the
  schema of the generated configuration. The contract does not set the
  installed version.
- **Version skew**: two nodes report different Talos versions. Version skew
  shows a running upgrade or a failed upgrade.

## Upgrade rules

The skill obeys these rules.

1. Upgrade to the latest patch of every intermediate minor version. Do not
   skip a minor version. The Talos documentation gives this rule. Example:
   v1.12.5 to v1.13.10 to v1.14.1.
2. Upgrade one control plane node at a time. Wait for the node and for etcd
   before you start the next node.
3. Do not use the flag `--force`. The flag skips the etcd checks.
4. Do not use the tag `latest`. Use an exact version tag.
5. Do not downgrade a node.
6. Do not change the contract during an upgrade.
7. Stop when a check fails. Do not continue to the next node.

## Workflow

Run the steps in order. Do not skip the checks.

### Step 1: Enumerate the nodes

```bash
scripts/list-nodes.sh
```

The output gives the role, the hostname, the address, the Talos version, the
Kubernetes ready state, and the cordon state of each node.

### Step 2: Run the preflight check

```bash
scripts/preflight.sh <target-version>
```

Example:

```bash
scripts/preflight.sh v1.14.1
```

The check does these things:

1. It tests that `talosctl` is installed.
2. It tests that the client certificate is not expired.
3. It tests that the cluster answers.
4. It tests that every node reports the same Talos version.
5. It tests that no node is cordoned.
6. It tests that every node is ready.
7. It tests the etcd health with `talosctl health`.
8. It tests that the target version exists in the Image Factory.
9. It tests that the target is an adjacent minor version.
10. It tests the schematic.

Stop when a check reports FAIL. Read the reason and correct the fault.

### Step 3: Build the upgrade plan

```bash
scripts/plan-upgrade.sh <target-version>
```

The script prints the ordered steps. Each step gives the image and the
command for each node. The plan puts the control plane nodes first.

### Step 4: Upgrade one node

```bash
TALOS_UPGRADE_CONFIRM=<target-version> scripts/upgrade-node.sh <node-address> <target-version>
```

Example:

```bash
TALOS_UPGRADE_CONFIRM=v1.13.10 scripts/upgrade-node.sh 10.0.0.40 v1.13.10
```

The script refuses to run without the confirmation variable. The script does
these things:

1. It reads the current version of the node.
2. It refuses a control plane node when another control plane node is not
   ready.
3. It runs `talosctl upgrade` with the flag `--wait`.
4. It reads the new version of the node.
5. It waits for the Kubernetes node to become ready.

### Step 5: Repeat step 4

Do these actions for each node:

1. Upgrade the first control plane node.
2. Run `scripts/verify.sh <target-version> --in-progress`.
3. Upgrade the second control plane node.
4. Run `scripts/verify.sh <target-version> --in-progress`.
5. Upgrade the third control plane node.
6. Run `scripts/verify.sh <target-version> --in-progress`.
7. Upgrade the worker nodes. The worker nodes do not hold etcd. You can
   upgrade the worker nodes one after the other.

The form `--in-progress` reports a node that runs the old version as a WARN.
Use this form between the nodes of a step.

### Step 6: Run the verification

```bash
scripts/verify.sh <target-version>
```

The check does these things:

1. It tests that every node reports the target version.
2. It tests that every node is ready.
3. It tests that no node is cordoned.
4. It runs `talosctl health`.
5. It prints the Kubernetes version and the Flux state.

Use the strict form after the last node of a step. The strict form fails
when a node does not report the target version.

### Step 7: Go to the next minor version

A step moves a node forward by one minor version. The target version v1.14.1
needs a first pass at version v1.13.10.

Repeat steps 2 to 6 for each intermediate minor version.

### Step 8: Apply the OpenTofu change

The installer image is pinned in `terraform/cluster.tf` as
`local.talos_install_image`. The talos provider follows the Talos SDK version.
A provider bump changes the generated default image. The pin keeps the wanted
image equal to the version that the nodes run.

1. Set `local.talos_install_image` to the version of the last step.
2. Run the plan and the apply:

```bash
tofu -chdir=terraform plan
tofu -chdir=terraform apply
```

The plan must show only in-place updates. The plan must show the new image in
the `install` block of the machine configuration. Stop when the plan shows a
replacement of the resource `talos_machine_secrets`.

Commit the file `terraform/.terraform.lock.hcl` when `tofu init` changes it.

### Step 9: Report

Report these items for each node:

- The node name and the node address.
- The old version and the new version.
- The result: upgraded or failed.
- The health result of the cluster.

Report the OpenTofu plan summary. Report the Kubernetes version.

## Safety

Use these rules without exception.

- Do not start an upgrade when a node is not ready.
- Do not start an upgrade when a node is cordoned.
- Do not start an upgrade when two nodes report different versions.
- Do not upgrade two control plane nodes at the same time.
- Do not skip a minor version.
- Do not run the flag `--force`.
- Do not run the command `tofu apply -replace=talos_machine_secrets.secrets`.
  This command makes new cluster secrets. It breaks the cluster.
- Do not change the contract to change the installed version.
- Do not continue after a failed check.
- Do not delete a node during an upgrade.

## Preview mode

Set `DRY_RUN=1` to print the commands without a change to the cluster.

```bash
DRY_RUN=1 scripts/upgrade-node.sh 10.0.0.40 v1.13.10
```

When `DRY_RUN=1` is set, follow this rule:

- Run the enumeration, the preflight check, and the plan steps.
- Produce the full report.
- Do not run the command `talosctl upgrade`.

## Helper scripts

- `scripts/list-nodes.sh` lists the nodes with the role and the version.
- `scripts/preflight.sh` checks the client, the cluster, and the target.
- `scripts/plan-upgrade.sh` builds the ordered upgrade plan.
- `scripts/upgrade-node.sh` upgrades one node. This script is the only script
  that changes the cluster.
- `scripts/verify.sh` checks the cluster after an upgrade step.

## Environment variables

| Name | Meaning | Default |
|---|---|---|
| `TALOS_UPGRADE_CONFIRM` | The target version. The upgrade script needs this value. | None |
| `TALOS_SCHEMATIC` | The schematic identifier for the image. | The empty schematic |
| `TALOS_ENDPOINT` | The node that answers the read commands. | The first endpoint of the talosconfig |
| `DRY_RUN` | Set to `1` to print the commands only. | None |
