#!/usr/bin/env bash

set -eu
set -o pipefail

# This script will copy changes to gfx/wr from a mozilla cinnabar repo into a
# webrender repo and generate a PR. It does so by exporting the patches from
# the mozilla repo using `git format-patch` and then importing them into the
# WR repo using `git am`. Presumably this path is well tested because Linus
# uses it. And it's simple and easy to debug so that's nice.

# Requirements:
# 1) Mozilla cinnabar repo. Find a place to create a new worktree that you won't
#    fiddle with, let's call it $MOZILLA_SRC. Then go to an existing checkout
#    and run this (with appropriate MOZILLA_SRC value):
#     git fetch origin master
#     git worktree add --track -b __wrsync $MOZILLA_SRC origin/master
#    Also create a starting __wrlastsync branch:
#     git branch __wrlastsync
#    Modify the MOZILLA_SRC var below to point to your worktree.
# 2) WebRender repo. Ditto as step 1, use appropriate $WEBRENDER_SRC:
#     git fetch origin master
#     git worktree add --track -b __wrsync $WEBRENDER_SRC origin/master
#    And create a branch to push from
#     git branch __wrlastsync
#    Modify the WEBRENDER_SRC var below as well
# 3) Generate SSH key like so and upload the public key to moz-gfx Github account
#     mkdir -p $HOME/.wrupater/moz-gfx-ssh
#     ssh-keygen -t rsa -b 4096 -f $HOME/.wrupdater/moz-gfx-ssh/id_rsa
# 4) Generate a personal access token for the moz-gfx Github account (under
#    Settings -> Developer Settings -> Personal access tokens) with the
#    public_repo scope (at least) and put it at $HOME/.wrupdater/ghapikey

# For the first sync, reset the __wrlastsync branch in your mozilla git repo to
# the last cset in mozilla-central that was synced over to the webrender repo.
# Everything else should be good (hopefully).
# Normally you want to run with CRON=1 for cron jobs; each invocation will
# do an incremental update from the last run. CRON=0 exists for debugging and
# only-use-if-you-know-what-you-are-doing setups.

# These should definitely be set
MOZILLA_SRC=${MOZILLA_SRC:-$HOME/zspace/gecko-sync-wr}
WEBRENDER_SRC=${WEBRENDER_SRC:-$HOME/zspace/webrender-sync}

# These can be overridden from the command line if desired for debugging/fiddling
MOZ_LAST_REV=${MOZ_LAST_REV:-__wrlastsync}
MOZ_NEW_REV=${MOZ_NEW_REV:-__wrsync}
CRON=${CRON:-0}
LOCAL_CHANGES=${LOCAL_CHANGES:-0}

# Internal variables, don't fiddle with these
TMPDIR=$HOME/.wrupdater/tmp
PATCHDIR=$TMPDIR/patches

if [ -d "$PATCHDIR" ]; then
    echo "Found a pre-existing dir at $PATCHDIR, assuming previous run failed. Aborting..."
    exit 1
fi
mkdir -p "$PATCHDIR"

# Useful for cron
echo "Running $0 at $(date)"

# Pull latest m-c, except if LOCAL_CHANGES=1 (which exists for debugging only)
pushd $MOZILLA_SRC
git checkout $MOZ_NEW_REV
if [[ "$LOCAL_CHANGES" == "0" ]]; then
    git pull
fi
# Generate patches and delete any that didn't touch gfx/wr
git format-patch -o "$PATCHDIR" -pk --relative=gfx/wr $MOZ_LAST_REV
find "$PATCHDIR" -size 0b -delete
# Insert hg rev into commit messages
for patch in $(find "$PATCHDIR" -type f); do
    GIT_REV=$(head -n 1 $patch | awk '/^From/ { print $2 }')
    HG_REV=$(git cinnabar git2hg $GIT_REV)
    awk -v "HG_REV=$HG_REV" \
        'BEGIN { done=0 } /^diff --git/ && done==0 { print "[wrupdater] From https://hg.mozilla.org/mozilla-central/rev/" HG_REV "\n"; done=1 } /^/ { print $0 }' \
        $patch > $TMPDIR/patch-with-hg-rev
    mv $TMPDIR/patch-with-hg-rev $patch
done
popd

PATCHCOUNT=$(find "$PATCHDIR" -type f | wc -l)
if [[ $PATCHCOUNT -eq 0 ]]; then
    rm -rf "$PATCHDIR"
    echo "No patches found, aborting..."
    exit 0
fi

# Pull latest WR, and rebase the __wrlastsync onto latest master. So any
# previous patches that got merged will drop out and we'll keep the ones that
# didn't.
pushd $WEBRENDER_SRC
git checkout __wrsync
git pull
if [[ "$CRON" == "1" ]]; then
    git checkout __wrlastsync
    git rebase __wrsync
else
    git checkout -B __wrtestsync __wrsync
fi

# Apply new patches
git am $PATCHDIR/*

# Delete patchdir and update cinnabar branch to indicate successful ownership
# transfer of patches.
rm -rf "$PATCHDIR"
if [[ "$CRON" == "1" ]]; then
    pushd $MOZILLA_SRC
    git branch -f $MOZ_LAST_REV
    popd
fi

# Force-update the PR branch and try to generate a PR. If there's a pre-existing
# PR the force-update should just update it with new patches and (untested) the
# attempt to create a new PR will fail, which is fine. Otherwise this should
# create a new PR.
if [[ "$CRON" == "1" ]]; then
    GIT_SSH_COMMAND='ssh -i ~/.wrupdater/moz-gfx-ssh/id_rsa -o IdentitiesOnly=yes' git push moz-gfx +__wrlastsync
    echo '{ "title": "Re-sync from mozilla-central", "body": "Incoming changes from mozilla-central!", "head": "moz-gfx:__wrlastsync", "base": "master" }' > $HOME/.wrupdater/pull_request
    curl -i -H "Accept: application/vnd.github.v3+json" -d "@$HOME/.wrupdater/pull_request" -u "moz-gfx:$(cat $HOME/.wrupdater/ghapikey)" "https://api.github.com/repos/servo/webrender/pulls"
fi
popd
