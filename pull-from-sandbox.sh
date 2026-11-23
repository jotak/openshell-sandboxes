#!/usr/bin/env bash
# pull-from-sandbox.sh — bring the agent's commits from a sandbox repo back into
# the matching host repo. Mirror of push-to-sandbox.sh.
#
# Usage:
#   pull-from-sandbox.sh name-in-sandbox [/path/to/host/repo]
#   (host repo defaults to the current directory)
#
# Flow: inside the sandbox, bundle exactly the commits that are NOT in the
# uploaded state (refs/remotes/origin/*) — i.e. the agent's new work, usually a
# few kB — then download it and `git fetch` it into the host repo under
# refs/remotes/sandbox/*. Finally integrate, fast-forward-only:
#   - branch new on the sandbox side       -> created locally (no upstream set)
#   - local branch behind the sandbox one  -> fast-forwarded (also when it is
#                                              the currently checked-out branch)
#   - diverged (you committed on the host) -> left alone, reported with a hint
# Commits keep their exact SHAs. Nothing is ever pushed and nothing that is not
# a fast-forward is ever rewritten — the summary prints the push commands.
#
# Env: SANDBOX_NAME (default: goose-desktop)

set -euo pipefail

SANDBOX_NAME="${SANDBOX_NAME:-goose-desktop}"
WORKSPACE="/workspace"

die() { echo "error: $*" >&2; exit 1; }

[[ $# -ge 1 && $# -le 2 ]] || die "usage: $0 name-in-sandbox [/path/to/host/repo]"

NAME=$1
HOST_REPO=${2:-$PWD}

[[ $NAME =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] \
  || die "invalid name-in-sandbox '$NAME' (letters, digits, . _ - only)"
[[ -d $HOST_REPO ]] || die "no such directory: $HOST_REPO"
HOST_REPO=$(cd "$HOST_REPO" && pwd) || die "cannot resolve $HOST_REPO"
git -C "$HOST_REPO" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || die "not a git work tree: $HOST_REPO"

openshell sandbox exec "$SANDBOX_NAME" -- true \
  || die "cannot exec into $SANDBOX_NAME (sandbox running?)"

openshell sandbox exec "$SANDBOX_NAME" -- git -C "$WORKSPACE/$NAME" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || die "$WORKSPACE/$NAME is not a git repo in the sandbox (push-to-sandbox.sh first?)"

OUT_BUNDLE="$NAME.out.bundle"
TMP=$(mktemp -d /tmp/pull-from-sandbox.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

echo ">> bundling new commits in $SANDBOX_NAME:$WORKSPACE/$NAME (everything beyond origin/*)"
# --branches --tags ^<every origin ref>: only the agent's work; branches with no
# new commits are silently dropped by git, and with no new work at all git
# refuses to create an empty bundle — that is the "nothing to pull" signal.
if ! out=$(openshell sandbox exec "$SANDBOX_NAME" -- sh -c \
  "git -C '$WORKSPACE/$NAME' bundle create '$WORKSPACE/$OUT_BUNDLE' --branches --tags \
   \$(git -C '$WORKSPACE/$NAME' for-each-ref --format='^%(refname)' refs/remotes/origin)" 2>&1); then
  if grep -q "empty bundle" <<<"$out"; then
    echo ">> nothing to pull: no commits in $WORKSPACE/$NAME beyond the uploaded state (origin/*)."
    exit 0
  fi
  printf '%s\n' "$out" >&2
  die "bundle creation failed in the sandbox"
fi

echo ">> downloading"
openshell sandbox download "$SANDBOX_NAME" "$WORKSPACE/$OUT_BUNDLE" "$TMP" \
  || die "download failed"
LOCAL_BUNDLE="$TMP/$OUT_BUNDLE"
[[ -f $LOCAL_BUNDLE ]] || die "downloaded bundle not found at $LOCAL_BUNDLE"
openshell sandbox exec "$SANDBOX_NAME" -- rm -f "$WORKSPACE/$OUT_BUNDLE"

echo ">> fetching into $HOST_REPO (as refs/remotes/sandbox/*)"
git -C "$HOST_REPO" fetch "$LOCAL_BUNDLE" '+refs/heads/*:refs/remotes/sandbox/*' --tags

# --- integrate, fast-forward only ---
cur_branch=$(git -C "$HOST_REPO" rev-parse --abbrev-ref HEAD)
created=() ffed=() diverged=() behind=()

while IFS= read -r b; do
  [[ -z $b ]] && continue
  lb="refs/heads/$b"
  sb="refs/remotes/sandbox/$b"
  if ! git -C "$HOST_REPO" show-ref --verify --quiet "$lb"; then
    git -C "$HOST_REPO" branch --no-track "$b" "$sb"
    created+=("$b")
  elif [[ $(git -C "$HOST_REPO" rev-parse "$lb") == $(git -C "$HOST_REPO" rev-parse "$sb") ]]; then
    : # already up to date
  elif git -C "$HOST_REPO" merge-base --is-ancestor "$lb" "$sb"; then
    if [[ $b == "$cur_branch" ]]; then
      if git -C "$HOST_REPO" merge --ff-only "$sb"; then
        ffed+=("$b")
      else
        echo "warning: could not fast-forward checked-out $b (uncommitted changes?)" >&2
      fi
    else
      git -C "$HOST_REPO" branch -f "$b" "$sb"
      ffed+=("$b")
    fi
  elif git -C "$HOST_REPO" merge-base --is-ancestor "$sb" "$lb"; then
    behind+=("$b")
  else
    diverged+=("$b")
  fi
done < <(git -C "$HOST_REPO" for-each-ref --format='%(refname:lstrip=3)' refs/remotes/sandbox)

push_remote=$(git -C "$HOST_REPO" remote | head -n1 || true)
push_remote=${push_remote:-origin}

echo
echo "Pulled $SANDBOX_NAME:$WORKSPACE/$NAME -> $HOST_REPO"
for b in "${created[@]}";  do echo "  new branch:     $b   ->   git push -u $push_remote $b"; done
for b in "${ffed[@]}";     do echo "  fast-forwarded:  $b   ->   git push $push_remote $b"; done
for b in "${behind[@]}";   do echo "  sandbox behind local (nothing to integrate): $b"; done
for b in "${diverged[@]}"; do echo "  DIVERGED:       $b   ->   reconcile manually, e.g. git rebase sandbox/$b $b (or git merge sandbox/$b)"; done
if [[ ${#created[@]} -eq 0 && ${#ffed[@]} -eq 0 && ${#behind[@]} -eq 0 && ${#diverged[@]} -eq 0 ]]; then
  echo "  (no branch changes to integrate)"
fi
if [[ -z $(git -C "$HOST_REPO" remote) ]]; then
  echo "  note: no git remote configured in $HOST_REPO — push hints are illustrative"
fi
