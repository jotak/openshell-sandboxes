#!/usr/bin/env bash
# push-to-sandbox.sh — ship a host git repo into the OpenShell goose sandbox
# with full history and all branches (git bundle flow: `sandbox upload` strips
# .git, and `git clone` from inside is blocked by the read-only network policy).
#
# Usage:
#   push-to-sandbox.sh /path/to/repo [name-in-sandbox]
#
# - The sandbox copy lives at /workspace/<name-in-sandbox> (default: the repo's
#   basename). The name may deliberately differ from the basename: push the same
#   repo under several names to let several agents work on independent instances
#   of it in parallel — like `git worktree`, except each instance is a full clone
#   with its own branches (the same branch may be checked out in two instances).
# - First push: bundles every branch + tag, uploads the bundle (it stays at
#   /workspace/<name>.in.bundle and serves as the clone's `origin`), then clones
#   /workspace/<name> from it. Branches appear as origin/* — i.e. `origin/*`
#   is the uploaded state, so `git diff origin/main` shows the agent's work.
# - Push again (refresh): re-uploads the bundle (same path) and runs
#   `git fetch origin` inside the sandbox copy. Only origin/* refs move; the
#   agent's branches and working tree are never touched.
# - Uncommitted host changes are NOT shipped (bundles carry commits only);
#   the script warns when the work tree is dirty.
#
# Env: SANDBOX_NAME (default: goose-desktop)

set -euo pipefail

SANDBOX_NAME="${SANDBOX_NAME:-goose-desktop}"
WORKSPACE="/workspace"

die() { echo "error: $*" >&2; exit 1; }

[[ $# -ge 1 && $# -le 2 ]] || die "usage: $0 /path/to/repo [name-in-sandbox]"

HOST_REPO=$1
NAME=${2:-}

[[ -d $HOST_REPO ]] || die "no such directory: $HOST_REPO"
HOST_REPO=$(cd "$HOST_REPO" && pwd) || die "cannot resolve $HOST_REPO"
git -C "$HOST_REPO" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || die "not a git work tree: $HOST_REPO"

[[ -z $NAME ]] && NAME=$(basename "$HOST_REPO")
[[ $NAME =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] \
  || die "invalid name-in-sandbox '$NAME' (letters, digits, . _ - only)"

# Stable bundle name: overwritten on every push, stays in the sandbox as the
# repo's origin.
BUNDLE="$NAME.in.bundle"

TMP=$(mktemp -d /tmp/push-to-sandbox.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

if [[ -n $(git -C "$HOST_REPO" status --porcelain 2>/dev/null) ]]; then
  echo ">> note: $HOST_REPO has uncommitted changes — NOT included (bundles carry commits only)"
fi

echo ">> bundling $HOST_REPO (all branches + tags, full history)"
git -C "$HOST_REPO" bundle create "$TMP/$BUNDLE" --all

echo ">> uploading to $SANDBOX_NAME:$WORKSPACE/$BUNDLE"
openshell sandbox upload "$SANDBOX_NAME" "$TMP/$BUNDLE" \
  || die "upload failed (sandbox running? openshell sandbox start $SANDBOX_NAME)"

openshell sandbox exec "$SANDBOX_NAME" -- true \
  || die "cannot exec into $SANDBOX_NAME (sandbox running?)"

if openshell sandbox exec "$SANDBOX_NAME" -- git -C "$WORKSPACE/$NAME" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo ">> $WORKSPACE/$NAME already exists — refreshing origin/* from the new bundle"
  openshell sandbox exec "$SANDBOX_NAME" -- git -C "$WORKSPACE/$NAME" fetch origin
  echo ">> done. origin/* now matches this push; the agent's branches and working tree were not touched."
elif openshell sandbox exec "$SANDBOX_NAME" -- test -e "$WORKSPACE/$NAME"; then
  die "$WORKSPACE/$NAME exists but is not a git repo (plain upload?) — remove it or pick another name"
else
  echo ">> cloning into $WORKSPACE/$NAME (origin = the uploaded bundle, branches appear as origin/*)"
  openshell sandbox exec "$SANDBOX_NAME" -- git clone "$WORKSPACE/$BUNDLE" "$WORKSPACE/$NAME"
  echo ">> done."
fi

echo
echo "Open in Codium:"
echo "  code --folder-uri vscode-remote://ssh-remote+openshell-$SANDBOX_NAME.default$WORKSPACE/$NAME"
echo "Pull the work back with:"
echo "  ./pull-from-sandbox.sh $NAME $HOST_REPO"
