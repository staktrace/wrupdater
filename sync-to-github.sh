#!/usr/bin/env bash

set -eux
set -o pipefail

# This script will copy changes to gfx/wr from a mozilla mercurial repo into
# a webrender repo clone and generate/update a PR.
#
# Prerequisites:
#  - This script must be run on Linux (uses Linux `readlink` semantics)
#  - libgit2 version 0.27.* must be installed on the system:
#      wget -nv https://github.com/libgit2/libgit2/archive/v0.27.8.tar.gz
#      tar xf v0.27.8.tar.gz && rm -rf v0.27.8.tar.gz
#      pushd libgit2-0.27.8
#      cmake . && make && sudo make install
#      popd
#      sudo ldconfig
#  - python3 must be installed on the system
#  - The MOZILLA_SRC environment variable should point to a mercurial clone
#    of mozilla-central
#  - the ~/.wrupdater/secrets folder must exist and contain a ghapikey file.
#    This must contain an access token (generate by going to Github,
#    Settings -> Developer Settings -> Personal access tokens) with at least the
#    public_repo OAuth scope.
#
# What the script does:
#  - Uses the ~/.wrupdater directory for staging. In this directory:
#    - secrets/ contains access credentials as described above
#    - tmp/ contains temp files
#    - venv/ contains a python3 virtualenv with dependencies
#    - webrender/ contains a git clone of the webrender repo
#    Other than the secrets folder, everything is created and initialized
#    if it doesn't already exist.
#  - Pulls the latest upstream changes into the mercurial and git repositories
#  - Runs the converter.py script, which updates the wrupdater branch in the
#    git repo to have all the latest mozilla-central changes
#  - Creates a PR (or force-updates the pre-existing PR) with the changes
#  - Drops a comment on the PR to tell bors to merge

if [ "$(uname)" != "Linux" ]; then
    echo "Error: this script must be run on Linux" > /dev/stderr
    exit 1
fi

# These should definitely be set
MOZILLA_SRC=${MOZILLA_SRC?"Error: The MOZILLA_SRC env var must point to a mercurial clone of mozilla-central"}

# Internal variables, don't fiddle with these
MYSELF=$(readlink -f $0)
MYDIR=$(dirname "${MYSELF}")
WORKDIR="$HOME/.wrupdater"
TMPDIR="$WORKDIR/tmp"

if [ ! -f "${WORKDIR}/secrets/ghapikey" ]; then
    echo "Error: no Github API token found at ${WORKDIR}/secrets/ghapikey" > /dev/stderr
    exit 1
fi

# Useful for cron
echo "Running $0 at $(date)"

mkdir -p "${TMPDIR}"

# Bring the webrender clone to a known good up-to-date state
if [ ! -d "${WORKDIR}/webrender" ]; then
    git clone https://github.com/servo/webrender "${WORKDIR}/webrender"
    pushd "${WORKDIR}/webrender"
    git remote add moz-gfx https://github.com/moz-gfx/webrender
    popd
else
    pushd "${WORKDIR}/webrender"
    git checkout master
    git pull
    popd
fi

HTTP_AUTH="moz-gfx:$(cat ${WORKDIR}/secrets/ghapikey)"

pushd "${WORKDIR}/webrender"
git fetch moz-gfx
git checkout -B wrupdater moz-gfx/wrupdater || git checkout -B wrupdater master
git push "https://${HTTP_AUTH}@github.com/moz-gfx/webrender" wrupdater:wrupdater
popd

# Bring the mozilla-central repo to a known good up-to-date state
pushd "${MOZILLA_SRC}"
hg pull -f -u https://hg.mozilla.org/mozilla-central/
popd

# Activate virtualenv, building it if needed
if [ ! -d "${WORKDIR}/venv" ]; then
    virtualenv --python=python3 "${WORKDIR}/venv"
fi
set +u # virtualenv tries to use undefined PS1, what a piece of trash
source "${WORKDIR}/venv/bin/activate"
set -u
pip install -r "${MYDIR}/converter-requirements.txt"

# Run the converter
pushd "${MOZILLA_SRC}"
"${MYDIR}/converter.py" "${WORKDIR}/webrender"
popd

deactivate

# Check to see if we have changes that need pushing
pushd "${WORKDIR}/webrender"
git reset --hard  # converter.py might leave files out of sync
PATCHCOUNT=$(git log --oneline moz-gfx/wrupdater..wrupdater | wc -l)
if [[ ${PATCHCOUNT} -eq 0 ]]; then
    echo "No new patches found, aborting..."
    exit 0
fi

# Collect PR numbers of PRs opened on Github and merged to m-c
set +e
FIXES=$(git log master..wrupdater | grep "\[wrupdater\] From https://github.com/servo/webrender/pull" | sed -e "s%.*pull/%Fixes #%")
echo $FIXES
set -e

git push "https://${HTTP_AUTH}@github.com/moz-gfx/webrender" +wrupdater:wrupdater

CURL_HEADER="Accept: application/vnd.github.v3+json"
CURL=(curl -sSfL -H "${CURL_HEADER}" -u "${HTTP_AUTH}")

# Check if there's an existing PR open
"${CURL[@]}" "https://api.github.com/repos/servo/webrender/pulls?head=moz-gfx:wrupdater" | tee "${TMPDIR}/pr.get"
set +e
COMMENT_URL=$(cat "${TMPDIR}/pr.get" | ${MYDIR}/read-json.py "0/comments_url")
HAS_COMMENT_URL=$?
set -e

if [ ${HAS_COMMENT_URL} -ne 0 ]; then
    # The PR doesn't exist yet, so let's create it
    echo '{ "title": "Sync changes from mozilla-central", "body": "'"${FIXES}"'", "head": "moz-gfx:wrupdater", "base": "master" }' > "${TMPDIR}/pr.create"
    "${CURL[@]}" -d "@${TMPDIR}/pr.create" "https://api.github.com/repos/servo/webrender/pulls" | tee "${TMPDIR}/pr.response"
    COMMENT_URL=$(cat "${TMPDIR}/pr.response" | ${MYDIR}/read-json.py "comments_url")
fi

# At this point COMMENTS_URL should be set, so leave a comment to tell bors
# to merge the PR.
echo '{ "body": "@bors-servo r+" }' > "${TMPDIR}/bors_rplus"
"${CURL[@]}" -d "@${TMPDIR}/bors_rplus" "${COMMENT_URL}"
