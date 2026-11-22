# Facts the release scripts must agree about. Sourced, not run.
#
# One version source,
# Developer ID by keychain hash, notary credentials from the environment or
# from .env.notarize at the repository root (never exported).

# The release's names. An instance with a suffix adds it to each:
# the names come from the functions below, which match instance.rs.
LC_BUNDLE_ID="dev.localcron.app"
LC_GH_REPO="${LC_GH_REPO:-shchahrykovich/localcron}"
LC_MIN_MACOS="14.0"

# The version in [workspace.package] of Cargo.toml.
#   lr_version <path to Cargo.toml>
lr_version() {
    awk '
        /^\[workspace\.package\]/ { in_pkg = 1; next }
        /^\[/                     { in_pkg = 0 }
        in_pkg && /^version[[:space:]]*=/ { gsub(/[",]/, "", $3); print $3; exit }
    ' "$1"
}

# Rewrite the version in [workspace.package].
#   lr_set_version <path to Cargo.toml> <x.y.z>
lr_set_version() {
    local file="$1" new="$2" tmp
    tmp="$(mktemp)"
    awk -v new="$new" '
        /^\[workspace\.package\]/ { in_pkg = 1; print; next }
        /^\[/                     { in_pkg = 0 }
        in_pkg && /^version[[:space:]]*=/ { print "version = \"" new "\""; in_pkg = 0; next }
        { print }
    ' "$file" > "$tmp" && mv "$tmp" "$file"
}

# Read .env.notarize into this shell, only when the environment has nothing.
# The values stay shell variables: exporting them would hand an app-specific
# password to every child process of the build.
#   lr_load_signing_env <repository root>
lr_load_signing_env() {
    local file="$1/.env.notarize"
    if [[ -n "${APPLE_ID:-}${APPLE_API_KEY:-}" ]]; then
        return 0
    fi
    if [[ -f "$file" ]]; then
        # shellcheck disable=SC1090
        . "$file"
    fi
    return 0
}

# Keychain hash of a "Developer ID Application" identity, or nothing.
#   lr_developer_id [team id]
lr_developer_id() {
    local team="${1:-}" found=""
    if [[ -n "$team" ]]; then
        found="$(security find-identity -v -p codesigning 2>/dev/null | awk -v want="($team)" '
            /Developer ID Application/ && index($0, want) { print $2; exit }')"
    fi
    if [[ -z "$found" ]]; then
        found="$(security find-identity -v -p codesigning 2>/dev/null | awk '
            /Developer ID Application/ { print $2; exit }')"
    fi
    printf '%s' "$found"
}

# Arguments for `xcrun notarytool`, one per line; answers 1 when incomplete.
#   if lines="$(lr_notary_credentials)"; then ... fi
lr_notary_credentials() {
    if [[ -n "${APPLE_API_KEY:-}" && -n "${APPLE_API_KEY_ID:-}" && -n "${APPLE_API_ISSUER:-}" ]]; then
        printf '%s\n' --key "$APPLE_API_KEY" --key-id "$APPLE_API_KEY_ID" --issuer "$APPLE_API_ISSUER"
        return 0
    fi
    if [[ -n "${APPLE_ID:-}" && -n "${APPLE_APP_SPECIFIC_PASSWORD:-}" && -n "${APPLE_TEAM_ID:-}" ]]; then
        printf '%s\n' --apple-id "$APPLE_ID" --password "$APPLE_APP_SPECIFIC_PASSWORD" --team-id "$APPLE_TEAM_ID"
        return 0
    fi
    return 1
}

lr_die() { printf 'error: %s\n' "$*" >&2; exit 1; }

# Stops a release whose tag would not hold the code in its image: the tag is
# made at a commit on GitHub, the image from this folder. So the folder must
# have no uncommitted changes and HEAD must be origin/main. With
# allow_version 1 (a rerun with --no-bump), Cargo.toml and Cargo.lock may
# hold the version an earlier run set.
#   lr_check_pushed <repository root> <allow_version 0|1>
lr_check_pushed() {
    local root="$1" allow_version="$2" dirty ahead behind
    git -C "$root" fetch -q origin main || lr_die "cannot fetch origin main"
    dirty="$(git -C "$root" status --porcelain --untracked-files=no)"
    if [[ "$allow_version" == 1 ]]; then
        dirty="$(grep -vE '^.. (Cargo\.toml|Cargo\.lock)$' <<<"$dirty" || true)"
    fi
    [[ -z "$dirty" ]] || lr_die "uncommitted changes would be in the image but not in the tag; commit and push them first:"$'\n'"$dirty"
    ahead="$(git -C "$root" rev-list --count origin/main..HEAD)"
    [[ "$ahead" == 0 ]] || lr_die "$ahead commit(s) are not on GitHub, so the tag would not have them: run git push origin main first"
    behind="$(git -C "$root" rev-list --count HEAD..origin/main)"
    [[ "$behind" == 0 ]] || lr_die "HEAD is $behind commit(s) behind origin/main: run git pull first"
}

# An instance suffix: empty for the release, or "-" and 1 to 15 of a-z, 0-9.
#   lr_check_suffix <suffix>
lr_check_suffix() {
    [[ -z "$1" || "$1" =~ ^-[a-z0-9]{1,15}$ ]] ||
        lr_die "invalid instance suffix \"$1\": use \"\" or \"-\" followed by 1 to 15 of a-z and 0-9, like \"-dev\""
}

# Names of the instance with this suffix.
lr_app_name() { printf 'LocalCron%s' "$1"; }
lr_bundle_id() { printf '%s%s' "$LC_BUNDLE_ID" "$1"; }
lr_daemon_label() { printf '%s%s.daemon' "$LC_BUNDLE_ID" "$1"; }
lr_say() { printf '==> %s\n' "$*"; }
