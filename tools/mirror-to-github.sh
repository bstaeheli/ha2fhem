#!/bin/sh
# Mirror this repo to GitHub for HACS users.
#
# The Codeberg repo uses the SHA-256 object format, which GitHub does not
# support — so a plain push mirror is impossible. This script converts the
# history to SHA-1 via fast-export/fast-import and force-pushes all refs.
# Run it manually after pushes/tags you want visible on GitHub.
#
# Needs in env (see .envrc): GITHUB_MIRROR_USER, GITHUB_MIRROR_TOKEN,
# GITHUB_MIRROR_REPO (e.g. "user/ha2fhem").
set -eu
cd "$(dirname "$0")/.."

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

git init --quiet --bare --object-format=sha1 "$tmp/sha1.git"
git fast-export --all --signed-tags=strip --tag-of-filtered-object=drop \
    | git -C "$tmp/sha1.git" fast-import --quiet
git -C "$tmp/sha1.git" push --quiet --mirror \
    "https://${GITHUB_MIRROR_USER}:${GITHUB_MIRROR_TOKEN}@github.com/${GITHUB_MIRROR_REPO}.git"
echo "mirrored to github.com/${GITHUB_MIRROR_REPO}"
