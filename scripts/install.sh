#!/bin/bash
# Build and install a LocalCron instance on this Mac for development.
#
#   scripts/install.sh [--user] [--launch] [--suffix <suffix>] [--ad-hoc]
#
# By default this installs LocalCron-dev.app (suffix -dev), which runs next
# to the release with its own daemon, CLI, and folders
# It never touches LocalCron.app unless you pass --suffix "" on
# purpose.
#
# --user installs to ~/Applications instead of /Applications.
# The build is signed with your Developer ID when the keychain has one (no
# notarization): macOS ties the daemon's launch constraint and the Keychain
# access of its secrets to the team, so both survive a rebuild. An ad-hoc
# build (--ad-hoc, or no identity) gets a new signature each time: macOS
# refuses the new daemon for 10 to 30 s and the app retries, and secrets
# stored by an older build cannot be read.
# The build is ad-hoc signed, so the updater will not replace it; install a
# release from GitHub to get self-updates.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=release-lib.sh
. "$ROOT/scripts/release-lib.sh"

dest_dir="/Applications"
launch=0
suffix="-dev"
ad_hoc=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --user) dest_dir="$HOME/Applications"; shift ;;
        --launch) launch=1; shift ;;
        --ad-hoc) ad_hoc=1; shift ;;
        --suffix) [[ $# -ge 2 ]] || lr_die "--suffix needs a value, for example -dev, or \"\" for the release"
                  suffix="$2"; shift 2 ;;
        *) lr_die "unknown option $1" ;;
    esac
done
lr_check_suffix "$suffix"
app_name="$(lr_app_name "$suffix")"

sign=()
if [[ $ad_hoc == 0 ]]; then
    lr_load_signing_env "$ROOT"
    if [[ -n "$(lr_developer_id "${APPLE_TEAM_ID:-}")" ]]; then
        sign=(--developer-id)
    else
        lr_say "No Developer ID identity in the keychain: signing ad hoc"
    fi
fi
"$ROOT/scripts/build-app.sh" --suffix "$suffix" ${sign[@]+"${sign[@]}"}
mkdir -p "$dest_dir"
dest="$dest_dir/$app_name.app"
# Only this instance: its bundle id, its app, its daemon.
osascript -e "tell application id \"$(lr_bundle_id "$suffix")\" to quit" >/dev/null 2>&1 || true
# An ad-hoc build has a new signature each time, and launchd refuses to start
# the new daemon under the old registration ("spawn failed", exit 78). Remove
# the old job; the app registers the daemon again when it starts and finds it
# not running (AppModel.registerAgainIfStale).
launchctl bootout "gui/$(id -u)/$(lr_daemon_label "$suffix")" >/dev/null 2>&1 || true
rm -rf "$dest"
ditto "$ROOT/build/$app_name.app" "$dest"
lr_say "Installed $dest"
if [[ $launch == 1 ]]; then
    open "$dest"
else
    lr_say "Open $app_name to start its daemon."
fi
exit 0
