#!/bin/bash
# Build, notarize and publish a release on GitHub. The app's updater reads
# https://api.github.com/repos/shchahrykovich/localcron/releases/latest.
#
#   scripts/publish.sh [--patch|--minor|--major|--set X.Y.Z|--no-bump]
#
# Needs: gh logged in, a Developer ID identity, notary credentials.
# LC_ALLOW_UNNOTARIZED=1 publishes an image that failed stapler validation
# (the updater will refuse it; only for testing the release page).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=release-lib.sh
. "$ROOT/scripts/release-lib.sh"

gh auth status >/dev/null 2>&1 || [[ -n "${GH_TOKEN:-}" ]] || lr_die "gh is not logged in: run gh auth login"
empty="$(gh repo view "$LC_GH_REPO" --json isEmpty -q .isEmpty 2>/dev/null)" || lr_die "cannot see $LC_GH_REPO"
[[ "$empty" == "false" ]] || lr_die "$LC_GH_REPO has no commits; push the source first (a release needs a commit to tag)"

"$ROOT/scripts/release.sh" --notarize "$@"

version="$(lr_version "$ROOT/Cargo.toml")"
image="$ROOT/dist/localcron-$version.dmg"
name="$(basename "$image")"
tag="v$version"
[[ -f "$image" ]] || lr_die "$image was not built"
if ! xcrun stapler validate "$image" >/dev/null 2>&1 && [[ "${LC_ALLOW_UNNOTARIZED:-}" != "1" ]]; then
    lr_die "$image is not notarized; the updater would refuse it"
fi

notes="${LC_RELEASE_NOTES:-Download $name below, open it, and drag LocalCron to Applications. Installed copies update themselves.}"
lr_say "Creating release $tag on $LC_GH_REPO"
if gh release view "$tag" -R "$LC_GH_REPO" >/dev/null 2>&1; then
    lr_say "Release $tag exists; replacing its image"
else
    gh release create "$tag" -R "$LC_GH_REPO" --latest --title "LocalCron $version" --notes "$notes"
fi
gh release upload "$tag" "$image" -R "$LC_GH_REPO" --clobber

url="https://github.com/$LC_GH_REPO/releases/download/$tag/$name"
remote_size="$(curl -sfIL "$url" | awk 'tolower($1) == "content-length:" { n = $2 } END { gsub(/\r/, "", n); print n }')"
local_size="$(stat -f %z "$image")"
[[ "$remote_size" == "$local_size" ]] || lr_die "uploaded size $remote_size differs from $local_size"
lr_say "Published $url"
