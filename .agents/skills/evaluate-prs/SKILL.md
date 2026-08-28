---
name: evaluate-prs
description: >
  Evaluates the open pull requests in this homelab ops repository, detects
  breaking changes in the Renovate dependency bumps, and merges and applies
  only the pull requests that cause a net zero change in breaking changes.
  Use to triage, merge, and apply the safe Renovate dependency updates. Do
  not use for hand-written feature or infrastructure pull requests.
---

# Evaluate Pull Requests

Evaluate every open pull request to this repository. Merge and apply a pull
request only when it causes a net zero change in breaking changes. Report
the result for each pull request.

## Scope

This repository is a homelab. It uses Flux, Terraform, Helm, Ansible, and
Renovate. Almost every pull request is a Renovate dependency bump. The
Renovate branches have names like `renovate/<name>-<major>.x`.

A pull request that is a pure dependency bump is the normal case. A
hand-written pull request that changes Terraform or manifest logic is not
the normal case. Treat hand-written pull requests with more care.

## Prerequisites

Run these checks before you merge anything.

- `gh auth status` must be authenticated.
- The current branch must be `main`.
- The working tree must be clean: `git status` shows nothing to commit.
- Your local `main` must be in sync or ahead of `origin/main`.

Stop and report if a prerequisite fails.

## Definitions

Use these definitions for the decision.

### Breaking change

A breaking change disrupts the running homelab. It does not work without a
manual migration. A breaking change is one of these:

- A dependency version crosses a MAJOR version boundary. For a Terraform
  provider or a Helm chart, a MAJOR bump usually changes the required
  configuration or the resource schema.
- The diff changes a Kubernetes API version to an old version that is
  removed or renamed.
- The diff removes, renames, or moves a resource, namespace, or path that
  the existing infrastructure needs.
- The diff changes a CRD or a resource schema so that existing objects are
  no longer valid.
- The diff changes required configuration fields or removes a default that
  existing objects need.
- The diff changes encrypted manifests or the decryption setup
  (`.sops.yaml`) in a breaking way.

### Net zero breaking change

A pull request passes the gate only when it causes a net zero change in
breaking changes. This means the pull request introduces no breaking change
that the same pull request does not compensate. In practice, a safe pull
request introduces no breaking change at all.

A change with a net zero breaking effect is one of these:

- A patch version bump with no other change.
- A minor version bump inside the current MAJOR version, with no schema,
  API, or configuration change.
- An additive change only. It adds a resource, field, or value. It does not
  change existing behavior.
- A documentation, comment, or lockfile-only change.

## Decision matrix for version bumps

Most pull requests are version bumps. Use this order.

- **patch** bump: safe. It is net zero. Merge it.
- **minor** bump: usually safe. Check the diff for CRD, schema, or API
  changes. If you find none, it is net zero. Merge it.
- **major** bump: usually breaking. A pure Renovate MAJOR bump is not net
  zero. Do not merge it. It is net zero only if the same pull request also
  contains the required migration. This is rare.

## Workflow

Run the steps in order. Do not skip the diff review.

### Step 1: Enumerate the open pull requests

```bash
scripts/list-prs.sh
```

The output lists the pull request number, title, head branch, draft state,
and mergeability.

### Step 2: Classify the version bump for each pull request

```bash
scripts/classify-versions.sh <pr-number>
```

The output gives the highest bump class (major, minor, or patch) and the
version transitions.

### Step 3: Read the full diff for each pull request

```bash
gh pr diff <pr-number>
```

Also read the changed files that are not the lockfile. Check the whole diff
for any breaking change, not only the version line.

### Step 4: Judge the breaking-change effect

Apply the definitions and the decision matrix. Judge whether the pull
request causes a net zero change in breaking changes. Reject the pull
request if any breaking change is present and the same pull request does not
compensate it.

### Step 5: Record the start commit

Before you merge anything, record the current commit. You need it later
to decide whether OpenTofu must be checked:

```bash
export BEFORE_SHA="$(git rev-parse HEAD)"
```

### Step 6: Merge and apply the passing pull requests

For each pull request that passes the gate:

1. Merge it on GitHub:
   ```bash
   gh pr merge <pr-number> --merge
   ```
2. Apply it to the local checkout:
   ```bash
   git checkout main
   git pull --ff-only origin main
   ```

The repository uses merge commits. Confirm this in `git log` before you run
a different merge mode. If the repository uses squash merges, use
`gh pr merge <pr-number> --squash`.

The cluster applies the change after Flux reconciles `main`. Pulling the
local checkout keeps the working copy in sync.

### Step 7: Check OpenTofu safety

This repository uses OpenTofu (`tofu`) to manage resources. Some pull
requests change helm chart pins or provider versions in `.tf` files and in
`.terraform.lock.hcl`. Those changes need an OpenTofu plan to confirm they
are safe.

Run the OpenTofu check:

```bash
scripts/tofu-check.sh "$BEFORE_SHA"
```

The check does these things:

1. Compares `$BEFORE_SHA` to `HEAD` to find changed tofu files.
2. Runs `tofu init` to install any new provider plugins.
3. Runs `tofu plan` (read-only, never `apply`).
4. Reports the plan summary, the resource changes, and any errors.

Judge the result like this:

- **PLAN_SAFE=true**: the merged changes are safe. No resource is created,
  destroyed, or replaced. Only expected in-place updates are present.
- **PLAN_SAFE=false**: the plan shows a breaking change. Report the changed
  resource and stop. Do not proceed further.
- **PLAN_UNKNOWN=true**: the plan did not complete. Report the error lines.
  A state-lock error from a running `apply` is not a breaking change. It is
  a tooling conflict. A missing credential is a separate configuration fix.

Never run `tofu apply`. The OpenTofu check is read-only.

An OpenTofu plan sometimes finds an invalid or expired credential. That is
not a breaking change from the merged pull requests. Report it as a separate
fix item. Give the user the exact variable or token that needs attention.

After `tofu init`, it may add hash lines to `.terraform.lock.hcl`. Report
this. Recommend committing the lockfile change.

### Step 8: Report

Report the result for every pull request in the list. For each one, state:

- The pull request number and title.
- The version bump class.
- The verdict: merged, or rejected.
- The reason for a rejection.

Do not silently skip pull requests. Report every one.

In the same report, add the OpenTofu check result:

- The plan summary line.
- Whether the plan is safe, unsafe, or unknown.
- Any credential or lockfile action the user must take.

## Safety

Use these rules without exception.

- Do not merge a pull request that has a breaking change.
- Do not merge a pull request that has an unclear diff.
- Do not merge a draft pull request.
- Do not merge a pull request that is not mergeable. Check
  `mergeable` in the list output. It must be `MERGEABLE`.
- Do not override a rejection.
- Do not hand-edit Terraform, manifests, or HCL files.
- Do not decrypt secrets while you review a diff.
- Do not change the `.sops.yaml` file.
- Never run `tofu apply`. The OpenTofu check is read-only.

## Preview mode

Set `DRY_RUN=1` to report the verdicts without changing the repository:

```bash
DRY_RUN=1 gh pr diff <pr-number>
```

When `DRY_RUN=1` is set, follow this rule:

- Run the enumeration, classification, and diff review steps.
- Produce the full report.
- Do not run any `gh pr merge` command.
- Do not run any `git pull` command.

This lets you review the verdicts before you make any change.

## Helper scripts

- `scripts/list-prs.sh` lists the open pull requests.
- `scripts/classify-versions.sh` classifies the version bumps in one pull
  request.
- `scripts/tofu-check.sh` checks whether OpenTofu needs to run, runs the
  plan, and reports the safety verdict. It never runs `tofu apply`.
