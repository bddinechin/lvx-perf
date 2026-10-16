#!/usr/bin/env bash
# Part of the LVX project, under the Apache License v2.0 with LLVM Exceptions.
# See LICENSE.TXT in the root of this repository for license information.
# SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception

# Initialize or update this clone's benchmark submodules, leaving each one on
# its branch.
#
#   ./sync-submodules.sh
#
# Use this rather than a plain `git submodule update`, which checks out the
# recorded commit as a DETACHED HEAD. That matters more here than in most
# superprojects: the harnesses write into their submodule's results/ and the
# series is the point, so a sweep run on a detached HEAD produces numbers with
# nowhere to be committed, and `git checkout` later discards them without a
# warning worth the name.

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

git submodule update --init --recursive

# Re-attach each submodule to the branch .gitmodules names for it, keeping the
# commit the superproject recorded.
# Re-attach each submodule to the branch .gitmodules names for it, keeping the
# commit the superproject recorded. `git submodule foreach` runs this under sh,
# so it stays POSIX: no ${var:0:8}, no arrays.
git submodule foreach --quiet '
    branch=$(git -C "$toplevel" config -f .gitmodules --get "submodule.$name.branch" || echo)
    if [ -z "$branch" ]; then
        echo "$name: no branch configured, left as-is"
        exit 0
    fi
    head=$(git rev-parse HEAD)
    if git show-ref --verify --quiet "refs/heads/$branch"; then
        git checkout --quiet "$branch"
    else
        git checkout --quiet -b "$branch" --track "origin/$branch" 2>/dev/null \
            || git checkout --quiet -B "$branch" "$head"
    fi
    now=$(git rev-parse HEAD)
    short_head=$(echo "$head" | cut -c1-8)
    short_now=$(echo "$now" | cut -c1-8)
    if [ "$now" != "$head" ]; then
        # The branch points somewhere other than the recorded commit. Say so
        # rather than silently leaving the submodule off what was measured.
        echo "$name: branch $branch is at $short_now, superproject records $short_head"
        echo "$name:   (commit the move here, or git checkout $head to go back)"
    else
        echo "$name: on $branch at $short_head"
    fi
'

echo
echo "Submodules are on their branches. Sweeps are run inside them;"
echo "snapshot the results with ./bin/lvx-perf-import."
