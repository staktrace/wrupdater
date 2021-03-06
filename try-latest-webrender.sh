#!/usr/bin/env bash

set -eu
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
#    WR_CSET -> set to a git revision in the WR repo that you want to use as the
#               version to copy. Defaults to master if not set.
#    HG_REV -> set to a hg revision in m-c or autoland that you want to use as
#              the base. Defaults to central if not set, or autoland if there
#              is already an update inflight on autoland.

# These should definitely be set
MOZILLA_SRC=${MOZILLA_SRC:-$HOME/zspace/test-mozilla-wr}
WEBRENDER_SRC=${WEBRENDER_SRC:-$HOME/zspace/test-webrender}

# For most general usefulness you will want to override these:
PUSH_TO_TRY=${PUSH_TO_TRY:-1}

# These can be overridden from the command line if desired
HG_REV=${HG_REV:-0}
WR_CSET=${WR_CSET:-master}
EXTRA_CRATES=${EXTRA_CRATES:-}
BUGNUMBER=${BUGNUMBER:-0}
REVIEWER=${REVIEWER:-kats}
CRON=${CRON:-0}

# Internal variables, don't fiddle with these
MYSELF=$(readlink -f $0)
AWKSCRIPT=$(dirname $MYSELF)/version-bump.awk
READJSON=$(dirname $MYSELF)/read-json.py
TMPDIR=$HOME/.wrupdater/tmp
AUTHOR=(-u "WR Updater Bot <graphics-team@mozilla.staktrace.com>")

mkdir -p $TMPDIR || true

# Useful for cron
echo "Running $0 at $(date)"

# Abort if any mq patches are applied (usually because the last attempt failed)
pushd $MOZILLA_SRC
APPLIED=$(hg qapplied | wc -l)
if [ "$APPLIED" -ne 0 ]; then
    echo "Unclean state, aborting..."
    exit 1
fi

hg pull https://hg.mozilla.org/mozilla-central/
hg pull https://hg.mozilla.org/integration/autoland/

if [ "$HG_REV" == "0" ]; then
    INFLIGHT=$(hg diff -r central -r autoland gfx/webrender_bindings/revision.txt | wc -l)
    if [ $INFLIGHT -ne 0 ]; then
        # There's an update inflight on autoland, so use that as the base
        # Use the autoland tag since we don't want to do an autoland push
        # per cron unless the WR cset changes.
        echo "Found update already inflight on autoland, using autoland base..."
        HG_REV="autoland"
    else
        # Otherwise use central
        HG_REV=$(hg id -i -r central)
    fi
fi

# Update webrender repo to desired copy rev
pushd $WEBRENDER_SRC
git checkout master
git pull
git checkout $WR_CSET
CSET=$(git log -1 | grep commit | head -n 1)
WRPR=$(git log -1 | awk '/Auto merge/ { print $4 }')
popd

if [[ "$CRON" == "1" ]]; then
    LAST_HG_BASE=$(cat $HOME/.wrupdater/last_hg_base || echo "")
    LAST_WR_TESTED=$(cat $HOME/.wrupdater/last_wr_tested || echo "")
    if [[ "$HG_REV" == "$LAST_HG_BASE" && "$CSET" == "$LAST_WR_TESTED" ]]; then
        echo "No change, aborting..."
        exit 0
    fi
fi

# Delete generated patches from the last time this ran. This may emit a
# warning if the patches don't exist; ignore the warning
hg qrm wr-update-code || true
hg qrm wr-revendor || true
hg qrm wr-regen-bindings || true

# Update to desired base rev
echo "Updating to base rev $HG_REV..."
hg update "$HG_REV"

# Copy over the main folders
pushd gfx/
if [ -d "wr" ]; then
    rm -rf wr
    cp -R $WEBRENDER_SRC wr
    rm -rf wr/.git wr/target
    cd wr
    TRAITS=api
    BINDINGS="$PWD/../webrender_bindings"
elif [ -d "webrender" ]; then
    rm -rf webrender webrender_traits webrender_api wrench
    cp -R $WEBRENDER_SRC/webrender .
    if [ -d $WEBRENDER_SRC/webrender_traits ]; then
        TRAITS=traits
    elif [ -d $WEBRENDER_SRC/webrender_api ]; then
        TRAITS=api
    fi
    cp -R $WEBRENDER_SRC/webrender_$TRAITS .
    cp -R $WEBRENDER_SRC/wrench .
    rm -rf wrench/reftests wrench/benchmarks wrench/script
    NUMDIRS=$(find wrench -maxdepth 1 -type d | wc -l)
    if [ $NUMDIRS -ne 3 ]; then
        echo "Error: wrench/ has an unexpected number of subfolders!"
        exit 1
    fi
    BINDINGS="$PWD/webrender_bindings"
else
    echo "Error: didn't find either gfx/webrender or gfx/wr!"
    exit 1
fi

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
DWROTE_VERSION=$(cat webrender_${TRAITS}/Cargo.toml | awk '/^dwrote/ { print $0; exit }')
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
echo $CSET | sed -e "s/commit //" > $BINDINGS/revision.txt
popd

if [[ $(hg status | wc -l) -eq 0 ]]; then
    echo "WR version in base HG rev is identical to target WR version, aborting..."
    exit 0
fi

if [ "$BUGNUMBER" == "0" ]; then
    BUGNUMBER=$(curl -s -H "Accept: application/json" https://bugzilla.mozilla.org/rest/bug/wr-future-update | $READJSON "bugs/0/id")
fi

# Save update to mq patch wr-update-code
hg addremove
if [ "$WRPR" != "" ]; then
    hg qnew "${AUTHOR[@]}" -l <(echo "Bug $BUGNUMBER - Update webrender to $CSET (WR PR $WRPR). r?$REVIEWER"; echo ""; echo "https://github.com/servo/webrender/pull/${WRPR:1}") wr-update-code
elif [ "$WR_CSET" == "master" ]; then
    hg qnew "${AUTHOR[@]}" -m "Bug $BUGNUMBER - Update webrender to $CSET. r?$REVIEWER" wr-update-code
else
    hg qnew "${AUTHOR[@]}" -m "Bug $BUGNUMBER - Update webrender to $WR_CSET ($CSET). r?$REVIEWER" wr-update-code
fi

# Advance to wr-toml-fixup, applying any other patches in the queue that are
# in front of it.
hg qgoto wr-toml-fixup

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
hg addremove
if [[ $(hg status | wc -l) -ne 0 ]]; then
    hg qnew "${AUTHOR[@]}" -m "Bug $BUGNUMBER - Re-vendor rust dependencies. r?$REVIEWER" wr-revendor
fi

# Regenerate bindings, save to mq patch wr-regen-bindings
rustup run nightly cbindgen toolkit/library/rust --lockfile Cargo.lock --crate webrender_bindings -o gfx/webrender_bindings/webrender_ffi_generated.h
if [[ $(hg status | wc -l) -ne 0 ]]; then
    hg qnew "${AUTHOR[@]}" -m "Bug $BUGNUMBER - Re-generate FFI header. r?$REVIEWER" wr-regen-bindings
fi

# Advance to wr-try, applying any other patches in the queue that are in front
# of it.
hg qgoto wr-try

# Do try pushes as needed.
if [ "$PUSH_TO_TRY" -eq 1 ]; then
    set +e
    mach try fuzzy -q "'qr" \
                   -q "base-toolchains" \
                   -q "'webrender "'!docker' \
                   -q "'build-linux/ "'!pgo' \
                   -q "'build-android-api-16/" \
               > $HOME/.wrupdater/pushlog 2>&1
    if [ $? -eq 0 ]; then
        if [[ "$CRON" == "1" ]]; then
            echo "$CSET" > $HOME/.wrupdater/last_wr_tested
            echo "$HG_REV" > $HOME/.wrupdater/last_hg_base
            echo "{ \"comment\": \"WR @ $CSET" > $HOME/.wrupdater/bug_comment
            if [ "$WRPR" != "" ]; then
                echo " - servo/webrender$WRPR -" >> $HOME/.wrupdater/bug_comment
            fi
            echo " on HG rev $HG_REV: " >> $HOME/.wrupdater/bug_comment
            grep "treeherder.*jobs" $HOME/.wrupdater/pushlog | sed -e 's#remote:##' >> $HOME/.wrupdater/bug_comment
            echo "\"}" >> $HOME/.wrupdater/bug_comment

            if [ -f $HOME/.wrupdater/bzapikey ]; then
                curl -H "Content-Type: application/json" -d "@$HOME/.wrupdater/bug_comment" "https://bugzilla.mozilla.org/rest/bug/$BUGNUMBER/comment?api_key=$(cat $HOME/.wrupdater/bzapikey)"
            fi
        fi
    else
        echo "Push failure!"
        cat $HOME/.wrupdater/pushlog
    fi
    set -e
    hg qpop -a
else
    echo "Skipping push to try because PUSH_TO_TRY != 1"
fi

popd
