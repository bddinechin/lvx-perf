#!/usr/bin/env bash
# Part of the LVX project, under the Apache License v2.0 with LLVM Exceptions.
# See LICENSE.TXT in the root of this repository for license information.
# SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception

# Synchronize this clone of lvx-perf with work pushed from another machine.
#
# Shared with lvx-csw, which carries the same script; keep the two in step.
#
# Run from anywhere:  ./sync-from-work.sh
#
# Beyond a plain "git pull && git submodule update", this handles the three
# things that silently go wrong in a submodule superproject:
#
#  1. `git submodule update` checks out the recorded commit as a DETACHED
#     HEAD, so a clone drifts off its branches the first time it updates.
#     .gitmodules carries `update = merge` for every submodule, which
#     keeps the branch -- but that field only reaches a clone's .git/config
#     via `git submodule init`, so this script runs it.
#
#  2. `git submodule init` does NOT overwrite a value already set locally.
#     A clone that has `submodule.<name>.update = checkout` from earlier
#     keeps detaching with no warning. This script clears such values.
#
#  3. `update = merge` keeps a branch you are ON; it cannot put you back on
#     one. Submodules already detached stay detached. This script re-attaches
#     them to the branch .gitmodules names -- but only when that is provably
#     lossless (see the containment check below). It does this TWICE, before
#     and after the clone step, because a submodule this clone has never seen
#     does not exist until then -- see reattach_detached().
#
# Nothing here rebases, resets, forces or discards. Anything it will not do
# safely, it reports and leaves alone.
set -uo pipefail

cd "$(dirname "$0")" || exit 1
ROOT=$(pwd)

say()  { printf '\n\033[1m== %s\033[0m\n' "$*"; }
info() { printf '   %s\n' "$*"; }
warn() { printf '   \033[33m!! %s\033[0m\n' "$*"; }

paths() { git config -f .gitmodules --get-regexp '^submodule\..*\.path$' | awk '{print $2}'; }
name_of() {  # path -> submodule name (they can differ)
  git config -f .gitmodules --get-regexp '^submodule\..*\.path$' \
    | awk -v p="$1" '$2 == p { sub(/^submodule\./, "", $1); sub(/\.path$/, "", $1); print $1 }'
}

# ---------------------------------------------------------------- 0. preflight
say "Checking for local work that a sync could disturb"
DIRTY=0
if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
    warn "superproject has uncommitted tracked changes:"
    git status --short --untracked-files=no | sed 's/^/      /'
    DIRTY=1
fi
for p in $(paths); do
    [ -d "$ROOT/$p/.git" ] || [ -f "$ROOT/$p/.git" ] || continue
    if [ -n "$(git -C "$ROOT/$p" status --porcelain --untracked-files=no)" ]; then
        warn "$p has uncommitted changes -- it will be left alone below"
        DIRTY=1
    fi
done
[ "$DIRTY" -eq 0 ] && info "clean"

# ------------------------------------------------------- 1. superproject pull
say "Pulling the superproject"
if ! git pull --ff-only; then
    warn "fast-forward pull failed -- you have local commits or diverged."
    warn "Resolve by hand (git pull --rebase, or merge), then re-run. Stopping."
    exit 1
fi

# ------------------------------------- 2. clear stale local 'update' settings
say "Clearing stale submodule.*.update values"
CLEARED=0
while read -r key val; do
    [ -z "${key:-}" ] && continue
    if [ "$val" != "merge" ]; then
        info "unsetting $key (was '$val')"
        git config --unset "$key"
        CLEARED=1
    fi
done < <(git config --local --get-regexp '^submodule\..*\.update$' 2>/dev/null)
[ "$CLEARED" -eq 0 ] && info "none stale"

# -------------------------------------------- 3. init: copy .gitmodules -> config
say "Running submodule init (copies url/branch/update into .git/config)"
git submodule sync --recursive >/dev/null
git submodule init
for p in $(paths); do
    n=$(name_of "$p")
    u=$(git config --get "submodule.$n.update" || true)
    [ "$u" = "merge" ] || warn "$p: update='$u' (expected 'merge')"
done

# ------------------------------------------------ 4. re-attach detached HEADs
# Factored into a function because it must run TWICE, for a reason that is not
# obvious from either call site.
#
# A submodule this clone has never seen DOES NOT EXIST until step 5 clones it,
# and `git submodule update` checks out the recorded commit as a detached HEAD.
# So this pass cannot reach a new submodule: it reports "will be cloned below"
# and moves on. A fresh clone therefore used to finish with exactly those left
# detached, the final report saying *DETACHED* with nothing to say what to do
# about it -- and the answer, "run the script again", was folklore. Reported
# 2026-10-09.
#
# It cannot simply be MOVED after step 5 instead: step 4b needs every submodule
# ON its branch to compare against origin, and 4b must itself run before step
# 5, since with update=merge a rewritten branch would be spliced back together.
# Hence once here to feed 4b, and once after the clone to catch what 5 created.
reattach_detached() {
    say "Re-attaching detached submodules to their declared branches${1:+ ($1)}"
    local attached=0 deferred=0 p d cur n br head
    for p in $(paths); do
        d="$ROOT/$p"
        if [ ! -e "$d/.git" ]; then
            info "$p: not initialized yet (cloned in step 5, re-attached after)"
            deferred=$((deferred+1)); continue
        fi
        cur=$(git -C "$d" branch --show-current)
        [ -n "$cur" ] && continue                      # already on a branch

        n=$(name_of "$p")
        br=$(git config -f .gitmodules --get "submodule.$n.branch" || true)
        [ -n "$br" ] || { warn "$p: detached and .gitmodules names no branch -- skipped"; continue; }

        if [ -n "$(git -C "$d" status --porcelain --untracked-files=no)" ]; then
            warn "$p: detached but has uncommitted changes -- not touching it"
            continue
        fi

        git -C "$d" fetch -q origin "$br" 2>/dev/null
        head=$(git -C "$d" rev-parse HEAD)
        # Only attach when the branch already CONTAINS the detached commit.
        # Otherwise the detached HEAD holds work the branch does not, and
        # checking out the branch would strand it.
        if git -C "$d" merge-base --is-ancestor "$head" "origin/$br" 2>/dev/null; then
            git -C "$d" checkout -q "$br" 2>/dev/null || git -C "$d" checkout -q -b "$br" "origin/$br"
            info "$p -> $br"
            attached=1
        else
            warn "$p: HEAD $(git -C "$d" rev-parse --short HEAD) is NOT contained in origin/$br."
            warn "     It may hold commits that branch lacks. Left detached -- inspect with:"
            warn "     git -C $p log --oneline origin/$br..HEAD"
        fi
    done
    [ "$attached" -eq 0 ] && [ "$deferred" -eq 0 ] && info "nothing to re-attach"
    return 0
}

reattach_detached ""

# ------------------------------------- 4b. detect rewritten (rebased) history
# `update = merge` is the right default, but it is exactly wrong when the
# other machine REBASED a submodule branch and force-pushed: the local branch
# and origin then share no tip, and merging splices the pre-rebase commits
# back in alongside their rewritten twins -- every commit duplicated, or a
# pile of conflicts. Detect that here, before step 5 can do it.
#
# `git cherry` compares by patch-id, which is what makes the two cases
# distinguishable: after a pure rebase every local commit has an equivalent
# upstream ('-'), so discarding the local branch loses nothing. A '+' means a
# commit whose patch is genuinely absent upstream -- real local work.
say "Checking for rebased/rewritten submodule branches"
DIVERGED=0
for p in $(paths); do
    d="$ROOT/$p"
    [ -e "$d/.git" ] || continue
    br=$(git -C "$d" branch --show-current)
    [ -n "$br" ] || continue                        # detached: handled above
    git -C "$d" fetch -q origin "$br" 2>/dev/null || continue
    git -C "$d" rev-parse --verify -q "origin/$br" >/dev/null || continue

    head=$(git -C "$d" rev-parse HEAD)
    # Fast-forwardable (or already up to date) -- nothing to worry about.
    git -C "$d" merge-base --is-ancestor "$head" "origin/$br" && continue
    # Strictly ahead: the normal state between committing and pushing. Not a
    # divergence -- there is nothing upstream to reconcile with.
    git -C "$d" merge-base --is-ancestor "origin/$br" "$head" && continue

    # Patches on the local branch that origin lacks, and vice versa. Which of
    # the two is empty says which side did the rewriting.
    #
    # patch-id alone is not quite enough: it hashes context lines too, so a
    # rebase across upstream churn that merely inserted a line NEXT TO one of
    # ours yields a different patch-id for an otherwise identical commit --
    # observed exactly once across the 26-commit lvx-mlir rebase. So a
    # local-only commit whose subject also appears upstream is treated as
    # accounted for. Subjects are weak evidence alone, but a commit that is
    # both unmatched by patch-id AND unmatched by subject is real local work.
    subjects_upstream=$(git -C "$d" log --format='%s' "origin/$br" 2>/dev/null)
    unique=0
    while read -r sha; do
        [ -n "$sha" ] || continue
        s=$(git -C "$d" log --format='%s' -1 "$sha")
        grep -qxF "$s" <<<"$subjects_upstream" || unique=$((unique+1))
    done < <(git -C "$d" cherry "origin/$br" "$br" 2>/dev/null | awk '$1=="+"{print $2}')
    missing=$(git -C "$d" cherry "$br" "origin/$br" 2>/dev/null | grep -c '^+' || true)
    if [ "${unique:-0}" -eq 0 ]; then
        warn "$p: origin/$br was rewritten (rebased + force-pushed elsewhere)."
        warn "     Every commit on your local '$br' already exists there as a"
        warn "     rewritten patch, so nothing would be lost. Run:"
        warn "         git -C $p reset --hard origin/$br"
    elif [ "${missing:-0}" -eq 0 ]; then
        warn "$p: THIS clone rewrote '$br' -- origin/$br is fully contained in"
        warn "     it as rewritten patches, and origin has nothing you lack."
        warn "     Nothing to sync here; publish from this machine instead:"
        warn "         git -C $p push --force-with-lease origin $br"
    else
        warn "$p: local '$br' and origin/$br have genuinely diverged --"
        warn "     $unique commit(s) only here, $missing only on origin:"
        git -C "$d" cherry -v "origin/$br" "$br" | grep '^+' | sed 's/^/        /'
        warn "     Rebase or merge it yourself."
    fi
    DIVERGED=1
done
if [ "$DIVERGED" -ne 0 ]; then
    warn "Stopping before 'git submodule update': with update=merge it would"
    warn "merge the diverged histories together. Resolve the above, re-run."
    exit 1
fi
info "no rewritten branches"

# ------------------------------------------------------- 5. update submodules
say "Updating submodules to the commits the superproject records"
git submodule update --init --recursive

# Anything step 5 just cloned is sitting on a detached HEAD: `git submodule
# update` checks out the recorded commit, not the branch. The first pass could
# not see those -- they did not exist yet -- so run it again now.
reattach_detached "after the clone step"

# ------------------------------------------------------------- 6. final report
say "Result"
printf '   %-26s %-14s %s\n' REPO BRANCH HEAD
printf '   %-26s %-14s %s\n' ---- ------ ----
printf '   %-26s %-14s %s\n' "lvx-perf (super)" \
       "$(git branch --show-current)" "$(git log --oneline -1 | cut -c1-40)"
for p in $(paths); do
    d="$ROOT/$p"
    [ -e "$d/.git" ] || { printf '   %-26s %s\n' "$p" "(not initialized)"; continue; }
    b=$(git -C "$d" branch --show-current)
    printf '   %-26s %-14s %s\n' "$p" "${b:-*DETACHED*}" \
           "$(git -C "$d" log --oneline -1 | cut -c1-40)"
done

echo
info "Any submodule marked '+' by 'git submodule status' has a checkout that"
info "differs from the recorded commit -- expected while you have local work,"
info "worth a look otherwise."
echo
