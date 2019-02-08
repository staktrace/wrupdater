#!/usr/bin/env bash

set -eux
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
MOZ_LOCAL_BRANCH=${MOZ_LOCAL_BRANCH:-0}
CRON=${CRON:-0}

# Internal variables, don't fiddle with these
TMPDIR=$HOME/.wrupdater/tmp
PATCHDIR=$TMPDIR/patches

# Useful for cron
echo "Running $0 at $(date)"

if [ -d "$PATCHDIR" ]; then
    echo "Found a pre-existing dir at $PATCHDIR, assuming previous run failed. Aborting..."
    exit 1
fi

# Pull latest m-c, or use MOZ_LOCAL_BRANCH if specified (for debugging only)
pushd $MOZILLA_SRC
if [[ "$MOZ_LOCAL_BRANCH" == "0" ]]; then
    git checkout __wrsync
    git pull
else
    git checkout $MOZ_LOCAL_BRANCH
fi
# Generate patches and delete any that didn't touch gfx/wr
mkdir -p "$PATCHDIR"
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

# Abort if there is no work to do (i.e. no patches to port)
PATCHCOUNT=$(find "$PATCHDIR" -type f | wc -l)
if [[ $PATCHCOUNT -eq 0 ]]; then
    rm -rf "$PATCHDIR"
    if [[ "$CRON" == "1" ]]; then
        pushd $MOZILLA_SRC
        git branch -f $MOZ_LAST_REV
        popd
    fi
    echo "No patches found, aborting..."
    exit 0
fi

# Pull latest WR, and rebase the __wrlastsync onto latest master. So any
# previous patches that got merged will drop out and we'll keep the ones that
# didn't. If we ever have stuff landing in GH before it gets into m-c (maybe
# some urgent patch needed by servo/other folks?) then this rebase should also
# handle that gracefully, as long as there are no merge conflicts. I haven't
# explicitly tested this though since it should be rare.
pushd $WEBRENDER_SRC
git checkout __wrsync
git pull
if [[ "$CRON" == "1" ]]; then
    git checkout __wrlastsync
    git rebase __wrsync
else
    git checkout -B __wrtestsync __wrlastsync
    git rebase __wrsync
fi

# Apply new patches
export GIT_COMMITTER_NAME="wrupdater"
export GIT_COMMITTER_EMAIL="graphics-team@mozilla.staktrace.com"
git am $PATCHDIR/* # || git am --skip # if a patch double-landed thwn skip the am failure

# Delete patchdir and update cinnabar branch to indicate successful ownership
# transfer of patch files.
rm -rf "$PATCHDIR"
if [[ "$CRON" == "1" ]]; then
    pushd $MOZILLA_SRC
    git branch -f $MOZ_LAST_REV
    popd
fi

# Force-update the PR branch and try to generate a PR. If there's a pre-existing
# PR the force-update should just update it with new patches and the
# attempt to create a new PR will fail, which is fine. Otherwise this should
# create a new PR. We detect which of the two cases occurred below, and then
# leave a comment on the PR requesting bors to merge.
if [[ "$CRON" == "1" ]]; then
    # TODO: do this push over https using the personal access token instead of SSH
    GIT_SSH_COMMAND='ssh -i ~/.wrupdater/moz-gfx-ssh/id_rsa -o IdentitiesOnly=yes' git push git@github.com:moz-gfx/webrender +__wrlastsync
    echo '{ "title": "Sync changes from mozilla-central", "body": "", "head": "moz-gfx:__wrlastsync", "base": "master" }' > $TMPDIR/pull_request
    curl -isS -H "Accept: application/vnd.github.v3+json" -d "@$TMPDIR/pull_request" -u "moz-gfx:$(cat $HOME/.wrupdater/ghapikey)" "https://api.github.com/repos/servo/webrender/pulls" | tee $TMPDIR/pr_response

    set +e
    grep "A pull request already exists for moz-gfx:__wrlastsync" $TMPDIR/pr_response
    ALREADY_EXISTS=$?
    grep '"issue_url":' $TMPDIR/pr_response
    NEW_ISSUE=$?
    set -e

    # Ensure we have a comment_url file with the PR number in there to post comments
    if [ $ALREADY_EXISTS -eq 0 ]; then
        # Old PR was force-updated, so we need to bors-servo r+ the old one again
        echo "Using existing PR"
    elif [ $NEW_ISSUE -eq 0 ]; then
        # New PR was created, so let's get the URL to publish comments to
        awk '/^Location:/ { sub(/\r/, "", $2); sub(/\/pulls\//, "/issues/", $2); print $2 "/comments" }' $TMPDIR/pr_response > $TMPDIR/comment_url
    else
        echo 'Unrecognized response from Github! The next run of this script will try again, I guess'
        exit 1
    fi

    # Leave a comment to tell bors to merge the PR
    echo '{ "body": "@bors-servo r+" }' > $TMPDIR/bors_rplus
    curl -isS -H "Accept: application/vnd.github.v3+json" -d "@$TMPDIR/bors_rplus" -u "moz-gfx:$(cat $HOME/.wrupdater/ghapikey)" "$(cat $TMPDIR/comment_url)" | tee $TMPDIR/comment_response
fi
popd
