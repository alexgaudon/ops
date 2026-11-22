#!/usr/bin/env bash
# Check by default. --apply is an explicit, potentially disruptive operation.
set -euo pipefail
umask 077

repo=${AGNES_OPS_ROOT:-/mnt/pool/ops}
sops=${AGNES_SOPS_BIN:-/mnt/pool/ops-tools/bin/sops}
export SOPS_AGE_KEY_FILE=${SOPS_AGE_KEY_FILE:-/mnt/pool/ops-tools/sops/age/keys.txt}
mode=check
case ${1-} in
  --check) shift ;;
  --apply) mode=apply; shift ;;
  --help) echo 'Usage: compose-update [--check|--apply] [stack]'; exit 0 ;;
  --*) echo 'Unknown option' >&2; exit 2 ;;
esac
[[ $# -le 1 ]] || { echo 'Specify at most one stack' >&2; exit 2; }

# Deliberately exclude TrueNAS apps and Dockge projects.
managed=(downloader dozzle-jellyfin jellyfin-prod nas-media paperless syncthing windows1 windows2)
stacks=("${managed[@]}")
if [[ $# = 1 ]]; then
  found=false
  for stack in "${managed[@]}"; do
    [[ $1 != "$stack" ]] || found=true
  done
  "$found" || { echo 'Unknown or unmanaged stack' >&2; exit 2; }
  stacks=("$1")
fi

cd "$repo"
[[ $(git rev-parse --show-toplevel) = "$PWD" ]] || {
  echo 'The deployment directory must be the Git checkout root' >&2; exit 1;
}
[[ $(git branch --show-current) = main ]] || { echo 'Expected branch main' >&2; exit 1; }
gitdir=$(git rev-parse --absolute-git-dir)
exec 9>"$gitdir/agnes-compose-update.lock"
flock -n 9 || { echo 'Another deployment/check is running' >&2; exit 1; }
[[ -z $(git status --porcelain --untracked-files=no) ]] || {
  echo 'Tracked files have local changes; refusing to continue' >&2; exit 1;
}

if [[ $mode = apply ]]; then
  git pull --ff-only origin main
fi
printf 'Mode: %s; checkout: %s\n' "$mode" "$(git rev-parse --short HEAD)"
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT

# Prepare and validate everything before changing environment files or services.
for stack in "${stacks[@]}"; do
  dir="$repo/compose/agnes/$stack"
  [[ -f $dir/compose.yaml ]] || { echo "$stack: missing definition" >&2; exit 1; }
  if [[ -f $dir/secrets.env ]]; then
    "$sops" decrypt "$dir/secrets.env" > "$work/$stack.env"
  elif [[ -f $dir/.env ]]; then
    cp "$dir/.env" "$work/$stack.env"
  else
    : > "$work/$stack.env"
  fi
  # Never print rendered configuration: it contains environment secrets.
  (cd "$dir" && docker compose --env-file "$work/$stack.env" config --quiet)
  containers=$(cd "$dir" && docker compose --env-file "$work/$stack.env" ps -a -q)
  [[ -n $containers ]] || {
    echo "$stack: no existing containers; initial deployments require separate approval" >&2; exit 1;
  }
  echo "$stack: configuration valid; existing project found"
done

if [[ $mode = check ]]; then
  echo 'Check complete. No Git pull, image pull, environment replacement, or container update performed.'
  exit 0
fi

for stack in "${stacks[@]}"; do
  dir="$repo/compose/agnes/$stack"
  if [[ -f $dir/secrets.env ]]; then
    # Rename on the destination filesystem so publication is atomic.
    envtmp=$(mktemp "$dir/.env.XXXXXXXX")
    if ! install -m 600 "$work/$stack.env" "$envtmp" || ! mv -f -- "$envtmp" "$dir/.env"; then
      rm -f -- "$envtmp"
      exit 1
    fi
  fi
  echo "$stack: pulling images and applying (containers may be recreated)"
  (
    cd "$dir"
    docker compose --env-file "$work/$stack.env" pull --quiet
    docker compose --env-file "$work/$stack.env" up -d --no-build --pull never --wait --wait-timeout 120
    docker compose --env-file "$work/$stack.env" ps
  )
done
echo 'Selected stacks applied successfully.'
