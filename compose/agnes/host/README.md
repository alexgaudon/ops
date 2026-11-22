# Agnes Git-based deployment

## Status

The helper supports Git-based management of the existing deployment directory.
Git cutover and command installation don't deploy services. The first live
deployment is a separate step: don't run `--apply` without approval for possible
service interruptions.

Activated on 2026-11-22: the existing deployment directory is now a clean
`main` checkout with a public HTTPS origin. The persistent command is available
in new root SSH sessions, and TrueNAS Post Init task 1 restores its PATH setup.
All eight projects passed check-only mode after cutover. Container IDs, start
times, and restart counts stayed unchanged. No `--apply` has been run.

Preparation checks on 2026-11-22:

- All eight live Compose definitions matched GitHub `main` at `b847bee`.
- All eight effective configurations matched the isolated Git checkout,
  including environment settings. Configuration contents weren't logged.
- The helper's check mode passed for all eight projects on Agnes.
- A second invocation was rejected while the deployment lock was held.
- Agnes has Git, flock, Docker Compose v2.29.1, and SOPS v3.13.1. The current
  age key can decrypt the media stack's encrypted environment.
- No live deployment, image pull, Git cutover, or command installation occurred.

These checks describe that snapshot, not a guarantee about later changes.

## Commands

```bash
# Validation only; also the default when no mode is given.
bash compose/agnes/host/compose-update.sh --check
bash compose/agnes/host/compose-update.sh --check paperless

# Potentially disruptive: pull Git, pull images, and reconcile containers.
bash compose/agnes/host/compose-update.sh --apply paperless
```

The eventual installed command is `compose-update`. It operates on
`/mnt/pool/ops`, on branch `main`, and refuses tracked local changes. GitHub
access uses the checkout's `origin`; public HTTPS access needs no deploy key.
`AGNES_OPS_ROOT` and `AGNES_SOPS_BIN` override paths for isolated testing.
The default SOPS executable is `/mnt/pool/ops-tools/bin/sops`. Its existing age
key is stored privately at `/mnt/pool/ops-tools/sops/age/keys.txt`, outside Git.
`SOPS_AGE_KEY_FILE` overrides that key location. Both live on the data pool so
the helper doesn't depend on packages or secrets installed in the TrueNAS OS.

Only these existing projects are managed: downloader, dozzle-jellyfin,
jellyfin-prod, nas-media, paperless, syncthing, windows1, and windows2.
TrueNAS apps and Dockge projects are excluded. A project without existing
containers is rejected. Stopped existing containers can be started by `--apply`.

Checks decrypt secrets into private temporary files, validate configuration,
and query containers. They don't pull Git/images, replace live environment
files, or reconcile containers. Apply validates all selected projects before
pulling images or changing services, then processes them in order. The Git pull
happens before validation and updates the whole checkout, even for one stack.
Application bind-mounted files must therefore be reviewed before applying.

Encrypted `secrets.env` takes precedence over a host-local `.env`. Before the
first deployment, confirm that decrypting it reproduces the intended live
settings. Never print rendered Compose configuration or decrypted secrets.

Apply stops at the first failure. Earlier projects may already have changed;
there is no automatic rollback. Mutable image tags can advance during an apply.
The helper does not stop whole stacks first, remove orphans, delete volumes,
or install a timer. The existing host script is not automatically replaced
when its repository copy changes.

## Cutover checklist

1. Back up live definitions and environment files outside the checkout.
2. Compare each live definition with GitHub `main`; preserve any divergence.
3. Inventory untracked files and confirm no checkout would overwrite them.
4. Attach Git to the existing directory without changing stack paths or names.
   Don't replace the live directory with a different checkout or use a reset.
5. Confirm tracked files match, environment files remain private and ignored,
   and existing data mounts and Compose project identities remain unchanged.
6. Run the helper in check mode against the live checkout.
7. Install the helper using a TrueNAS-persistent location and an explicit boot
   arrangement if a system-path wrapper is needed. Don't modify TrueNAS OS
   packages or assume changes to its root filesystem survive upgrades.
8. Obtain approval for one named stack's first apply. Record its images and
   configuration beforehand; inspect service health and logs afterwards.

Reverting Git alone doesn't restore a migrated database or a previous mutable
image. Recovery requires the saved configuration, known image versions, and
application-consistent data backups as appropriate.

## Command persistence

TrueNAS mounts `/usr` read-only. `install-command.sh` instead creates
`/mnt/pool/ops-tools/bin/compose-update` as a symlink to the executable helper
in this checkout and adds that persistent directory to root's Bash and Zsh PATH.
It refuses to overwrite an unrelated command and is safe to run repeatedly.
New root SSH sessions pick up the command; an existing shell can use the full
path or start a new session.

Register a TrueNAS **Post Init** command through the supported middleware/UI:

```bash
/bin/bash /mnt/pool/ops/compose/agnes/host/install-command.sh
```

Root uses Zsh for SSH commands, so the installer updates `.zshenv` as well as
`.bashrc`. Both changes only expose the tools directory in the shell PATH.

The boot task restores only command availability and root's PATH entries. It
never pulls Git, starts containers, or applies configuration. Boot persistence needs verification at
the next planned reboot; don't reboot solely to test it during this cutover.

The local Git exclude list should hide the pre-existing rollback archives and
cutover scratch directories, which may contain plaintext secrets. Keep those
archives private and outside any future commits.

## Tests

```bash
python3 -m unittest discover -s compose/agnes/host -p 'test_*.py' -v
```

Tests use fake Git, Docker, and SOPS commands. They never connect to Agnes.
