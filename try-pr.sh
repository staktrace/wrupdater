#!/usr/bin/env bash

set -eux
set -o pipefail

# This script updates webrender in a mozilla-central repo. It requires the
# companion awk scripts `version-bump.awk` and `read-json.py` to be in the same
# folder as itself.
#
# The default mode of operation applies the update and does a try push with all
# the relevant webrender jobs. If you don't want it to do the try push, (e.g.
# if you want to build locally and test stuff), then you can run with
# PUSH_TO_TRY=0 in the environment, i.e.:
#    PUSH_TO_TRY=0 ./try-latest-webrender.sh
#
# WARNING: this script may result in dataloss if you run it on repos with
# uncommitted changes, so don't do that. Commit your stuff first!
#
# Requirements:
# 1. You should have two unapplied mq patches in your repo, called "wr-toml-fixup"
#    and "wr-try". You can create these patches like so:
#      hg qnew wr-toml-fixup && hg qnew wr-try && hg qpop -a
#    Note that the order of these patches is important, wr-toml-fixup should be
#    ahead of wr-try in the queue.
#    These patches are markers that allow to inject other custom manual-fixup
#    patches at various points in the update process. Any Cargo.toml fixes need
#    need to go in patches that apply before wr-toml-fixup, and anything else
#    should go between wr-toml-fixup and wr-try.
# 2. Set the environment variables:
#    MOZILLA_SRC -> this should point to your mozilla-central checkout
#    WEBRENDER_SRC -> this should point to your webrender git clone
#    PUSH_TO_TRY -> set this to 0 to skip the try push which otherwise happens
#                   by default.
# 3. Set optional environment variables:
#    HG_REV -> set to a hg revision in m-c or autoland that you want to use as
#              the base. Defaults to central if not set, or autoland if there
#              is already an update inflight on autoland.

# These should definitely be set
MOZILLA_SRC=${MOZILLA_SRC:-$HOME/zspace/gecko}
WEBRENDER_SRC=${WEBRENDER_SRC:-$HOME/zspace/test-webrender}

# For most general usefulness you will want to override these:
PUSH_TO_TRY=${PUSH_TO_TRY:-1}

# These can be overridden from the command line if desired
HG_REV=${HG_REV:-0}
WRPR=${WRPR?"WRPR is required to be the numeric PR number (e.g. WRPR=3502)"}
EXTRA_CRATES=${EXTRA_CRATES:-}
BUGNUMBER=${BUGNUMBER:-0}
REVIEWER=${REVIEWER?"REVIEWER is required"}

# Internal variables, don't fiddle with these
MYSELF=$(readlink -f $0)
AWKSCRIPT=$(dirname $MYSELF)/version-bump.awk
READJSON=$(dirname $MYSELF)/read-json.py
TMPDIR=$HOME/.wrupdater/tmp
PATCHDIR=$TMPDIR/patches-incoming
AUTHOR="WR Updater Bot <graphics-team@mozilla.staktrace.com>"

mkdir -p $TMPDIR || true

# Abort if any mq patches are applied (usually because the last attempt failed)
pushd $MOZILLA_SRC
git checkout master
git pull
git fetch autoland

if [ "$HG_REV" == "0" ]; then
    INFLIGHT=$(git diff -r master -r _autoland gfx/wr | wc -l)
    if [ $INFLIGHT -ne 0 ]; then
        # There's an update inflight on autoland, so use that as the base
        echo "Found WR changes already inflight on autoland, using autoland base..."
        HG_REV=$(git cinnabar git2hg _autoland)
    else
        # Otherwise use central
        HG_REV=$(git cinnabar git2hg master)
    fi
fi

pushd $WEBRENDER_SRC
git branch -D __wrincoming || true
git fetch origin master pull/$WRPR/head:__wrincoming
mkdir -p "$PATCHDIR"
git format-patch -o "$PATCHDIR" -pk origin/master..__wrincoming
find "$PATCHDIR" -size 0b -delete
for patch in $(find "$PATCHDIR" -type f); do
    awk -v "WRPR=$WRPR" \
        'BEGIN { done=0 } /^diff --git/ && done==0 { print "[wrupdater] From https://github.com/servo/webrender/pull/" WRPR "\n"; done=1 } /^/ { print $0 }' \
        $patch > $TMPDIR/patch-with-pr-number
    mv $TMPDIR/patch-with-pr-number $patch
done
popd

if [ "$BUGNUMBER" == "0" ]; then
    echo '{ "product": "Core", "component": "Graphics: WebRender", "summary": "Land servo/webrender#'"$WRPR"' in mozilla-central", "version": "unspecified" }' > $TMPDIR/new_bug.params
    if [ -f $HOME/.wrupdater/bzapikey ]; then
        curl -sS -H "Content-Type: application/json" -d "@$TMPDIR/new_bug.params" "https://bugzilla.mozilla.org/rest/bug?api_key=$(cat $HOME/.wrupdater/bzapikey)" | tee $TMPDIR/new_bug.response
    else
        echo "No Bugzilla API key found! Create a bug manually and provide BUGNUMBER as an env var"
        exit 1
    fi
    BUGNUMBER=$(cat $TMPDIR/new_bug.response | $READJSON "id")
fi

# Update to desired base rev
echo "Updating to base rev $HG_REV..."
GIT_BASE=$(git cinnabar hg2git $HG_REV)
git checkout -B __wr_pr $GIT_BASE

# Apply patches
git am --directory=gfx/wr $PATCHDIR/*
rm -rf "$PATCHDIR"

pushd gfx/
BINDINGS="$PWD/webrender_bindings"
cd wr
TRAITS=api

# Do magic to update the webrender_bindings/Cargo.toml file with updated
# version numbers for webrender, webrender_api, euclid, app_units, log, etc.
WR_VERSION=$(cat webrender/Cargo.toml | awk '/^version/ { print $0; exit }')
WRT_VERSION=$(cat webrender_${TRAITS}/Cargo.toml | awk '/^version/ { print $0; exit }')
RAYON_VERSION=$(cat webrender/Cargo.toml | awk '/^rayon/ { print $0; exit }')
TP_VERSION=$(cat webrender/Cargo.toml | awk '/^thread_profiler/ { print $0; exit }')
EUCLID_VERSION=$(cat webrender_${TRAITS}/Cargo.toml | awk '/^euclid/ { print $0; exit }')
AU_VERSION=$(cat webrender_${TRAITS}/Cargo.toml | awk '/^app_units/ { print $0; exit }')
GLEAM_VERSION=$(cat webrender/Cargo.toml | awk '/^gleam/ { print $0; exit }')
LOG_VERSION=$(cat webrender/Cargo.toml | awk '/^log/ { print $0; exit }')
DWROTE_VERSION=$(cat webrender/Cargo.toml | awk '/^dwrote/ { print $0; exit }')
CF_VERSION=$(cat webrender_${TRAITS}/Cargo.toml | awk '/^core-foundation/ { print $0; exit }')
CG_VERSION=$(cat webrender_${TRAITS}/Cargo.toml | awk '/^core-graphics/ { print $0; exit }')
sed -e "s/webrender_traits/webrender_${TRAITS}/g" $BINDINGS/Cargo.toml | awk -f $AWKSCRIPT \
    -v wr_version="${WR_VERSION}" \
    -v wrt_version="${WRT_VERSION}" \
    -v rayon_version="${RAYON_VERSION}" \
    -v tp_version="${TP_VERSION}" \
    -v euclid_version="${EUCLID_VERSION}" \
    -v au_version="${AU_VERSION}" \
    -v gleam_version="${GLEAM_VERSION}" \
    -v log_version="${LOG_VERSION}" \
    -v dwrote_version="${DWROTE_VERSION}" \
    -v cf_version="${CF_VERSION}" \
    -v cg_version="${CG_VERSION}" \
    > $TMPDIR/webrender-bindings-toml
mv $TMPDIR/webrender-bindings-toml $BINDINGS/Cargo.toml
git add $BINDINGS/Cargo.toml
popd

# Run cargo update
# This might fail because of versioning reasons, so we try to detect that
# and run cargo update again with the crates that need bumping. It tries this
# up to 5 times before giving up
for ((i = 0; i < 5; i++)); do
    cargo update -p webrender_${TRAITS} -p webrender ${EXTRA_CRATES} >$TMPDIR/update_output 2>&1 || true
    cat $TMPDIR/update_output
    ADDCRATE=$(cat ${TMPDIR}/update_output | awk '/failed to select a version/ { print $8 }' | tr -d '`')
    if [ -n "$ADDCRATE" ]; then
        echo "Adding crate $ADDCRATE to EXTRA_CRATES"
        export EXTRA_CRATES="$EXTRA_CRATES -p $ADDCRATE"
    else
        break
    fi
done

# Re-vendor third-party libraries, save Cargo.lock+revendoring to mq patch wr-revendor
./mach vendor rust --ignore-modified # --build-peers-said-large-imports-were-ok
git add -A third_party/rust Cargo.*
git commit -m "Update crate versions for changes in WR PR #$WRPR." --author="$AUTHOR" || true

gfx-phab submit --upstream $GIT_BASE -b "$BUGNUMBER" -r "$REVIEWER" --yes

# Do try pushes as needed.
if [ "$PUSH_TO_TRY" -eq 1 ]; then
    set +e
    ./mach try fuzzy -q "'qr" \
                   -q "base-toolchains" \
                   -q "'webrender "'!docker' \
                   -q "'build-linux/ "'!pgo' \
                   -q "'build-android-api-16/" \
               2>&1 | tee $HOME/.wrupdater/pushlog
    RESULT=$?
    set -e
    if [ $RESULT -eq 0 ]; then
        echo "{ \"comment\": \"WR PR #$WRPR" > $HOME/.wrupdater/bug_comment.params
        echo " on HG rev $HG_REV: " >> $HOME/.wrupdater/bug_comment.params
        grep "treeherder.*jobs" $HOME/.wrupdater/pushlog | sed -e 's#remote:##' >> $HOME/.wrupdater/bug_comment.params
        echo "\"}" >> $HOME/.wrupdater/bug_comment.params

        if [ -f $HOME/.wrupdater/bzapikey ]; then
            curl -H "Content-Type: application/json" -d "@$HOME/.wrupdater/bug_comment.params" "https://bugzilla.mozilla.org/rest/bug/$BUGNUMBER/comment?api_key=$(cat $HOME/.wrupdater/bzapikey)"
        fi
    else
        echo "Push failure!"
    fi
else
    echo "Skipping push to try because PUSH_TO_TRY != 1"
fi

popd
