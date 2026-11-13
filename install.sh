#!/bin/sh
set -eu

PROGRAM=farpilot
DEFAULT_MANIFEST_URL=https://farpilot.polly.wang/latest.json
TMP=

log() {
    printf '  > %s\n' "$1"
}

warn() {
    printf '  ! %s\n' "$1"
}

die() {
    printf '  x %s\n' "$1" >&2
    exit 1
}

cleanup() {
    if [ -n "$TMP" ] && [ -d "$TMP" ] && [ ! -L "$TMP" ]; then
        rm -rf "$TMP"
    fi
}
trap cleanup EXIT HUP INT TERM

need() {
    command -v "$1" >/dev/null 2>&1 || die "requires '$1'"
}

is_semver() {
    semver_value=$1
    case "$semver_value" in
        ''|.*|*.|*..*|*[!0-9.]*) return 1 ;;
    esac
    semver_old_ifs=$IFS
    IFS=.
    set -- $semver_value
    IFS=$semver_old_ifs
    [ "$#" -eq 3 ] || return 1
    [ -n "$1" ] && [ -n "$2" ] && [ -n "$3" ] || return 1
    return 0
}

normalize_version() {
    normalized_version=$1
    case "$normalized_version" in
        v*) normalized_version=${normalized_version#v} ;;
    esac
    is_semver "$normalized_version" || die "version must use X.Y.Z or vX.Y.Z"
    printf '%s\n' "$normalized_version"
}

detect_target() {
    detected_os=${FARPILOT_UNAME_S:-$(uname -s)}
    detected_arch=${FARPILOT_UNAME_M:-$(uname -m)}
    detected_variant=${FARPILOT_UNAME_O:-}
    if [ -z "$detected_variant" ] && [ "$detected_os" = Linux ]; then
        detected_variant=$(uname -o 2>/dev/null || true)
    fi
    if [ "$detected_os" = Linux ] && [ "$detected_variant" = Android ]; then
        die "Android/Termux is not supported; SSH to a supported Host instead"
    fi
    case "$detected_os" in
        Darwin) target_os=macos ;;
        Linux) target_os=linux ;;
        *) die "unsupported OS: $detected_os" ;;
    esac
    case "$detected_arch" in
        x86_64|amd64) target_arch=x86_64 ;;
        aarch64|arm64) target_arch=aarch64 ;;
        *) die "unsupported architecture: $detected_arch" ;;
    esac
    TARGET=$target_os-$target_arch
}

require_https() {
    https_label=$1
    https_url=$2
    case "$https_url" in
        https://*) ;;
        *) die "$https_label URL must use HTTPS: $https_url" ;;
    esac
}

download() {
    download_url=$1
    download_destination=$2
    require_https download "$download_url"
    curl -fsSL --retry 3 --connect-timeout 10 --max-time 120 "$download_url" -o "$download_destination"
}

manifest_number() {
    manifest_file=$1
    manifest_name=$2
    awk -v name="\"$manifest_name\"" '
        index($0, name) {
            line = $0
            sub(/^.*:[[:space:]]*/, "", line)
            sub(/[[:space:],}]*$/, "", line)
            print line
            exit
        }
    ' "$manifest_file"
}

manifest_string() {
    manifest_file=$1
    manifest_name=$2
    awk -v name="\"$manifest_name\"" '
        index($0, name) {
            line = $0
            sub(/^.*:[[:space:]]*"/, "", line)
            sub(/"[[:space:],}]*$/, "", line)
            print line
            exit
        }
    ' "$manifest_file"
}

asset_string() {
    manifest_file=$1
    asset_target=$2
    asset_field=$3
    awk -v target="\"$asset_target\"" -v field="\"$asset_field\"" '
        !inside && index($0, target) && $0 ~ /[{][[:space:]]*$/ {
            inside = 1
            next
        }
        inside && $0 ~ /^[[:space:]]*}[,]?[[:space:]]*$/ {
            exit
        }
        inside && index($0, field) {
            line = $0
            sub(/^.*:[[:space:]]*"/, "", line)
            sub(/"[[:space:],}]*$/, "", line)
            print line
            exit
        }
    ' "$manifest_file"
}

select_hash_tool() {
    if command -v sha256sum >/dev/null 2>&1; then
        HASH_TOOL=sha256sum
    elif command -v shasum >/dev/null 2>&1; then
        HASH_TOOL=shasum
    elif command -v openssl >/dev/null 2>&1; then
        HASH_TOOL=openssl
    else
        die "SHA-256 verification requires sha256sum, shasum, or openssl"
    fi
}

hash_file() {
    hash_path=$1
    case "$HASH_TOOL" in
        sha256sum) sha256sum "$hash_path" | awk '{print tolower($1)}' ;;
        shasum) shasum -a 256 "$hash_path" | awk '{print tolower($1)}' ;;
        openssl) openssl dgst -sha256 "$hash_path" | awk '{print tolower($NF)}' ;;
    esac
}

validate_digest() {
    digest_value=$1
    [ "${#digest_value}" -eq 64 ] || die "manifest contains an invalid SHA-256 for $TARGET"
    printf '%s\n' "$digest_value" | awk '/^[0-9A-Fa-f]+$/ { found=1 } END { exit(found ? 0 : 1) }' \
        || die "manifest contains an invalid SHA-256 for $TARGET"
}

role=cli
requested_version=
dry_run=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        gateway)
            role=gateway
            shift
            break
            ;;
        --version)
            [ "$#" -ge 2 ] || die "--version requires a value"
            requested_version=$(normalize_version "$2")
            shift 2
            ;;
        --dry-run)
            dry_run=1
            shift
            ;;
        --)
            shift
            [ "$#" -eq 0 ] || die "unexpected positional argument: $1"
            ;;
        *) die "unknown argument: $1" ;;
    esac
done

if [ "$role" = gateway ]; then
    die "gateway installation is not available yet"
fi
[ "$#" -eq 0 ] || die "unexpected positional argument: $1"

detect_target
log "detected $TARGET"

if [ -n "${FARPILOT_MANIFEST_URL:-}" ]; then
    MANIFEST_URL=$FARPILOT_MANIFEST_URL
elif [ -n "$requested_version" ]; then
    MANIFEST_URL=https://github.com/Polly2014/FarPilot/releases/download/v${requested_version}/manifest.json
else
    MANIFEST_URL=$DEFAULT_MANIFEST_URL
fi
require_https manifest "$MANIFEST_URL"

need curl
need awk
select_hash_tool

TMP=$(mktemp -d)
chmod 700 "$TMP"
manifest_path=$TMP/manifest.json
log "fetching release manifest"
download "$MANIFEST_URL" "$manifest_path" || die "failed to download release manifest"

schema_version=$(manifest_number "$manifest_path" schema_version)
[ "$schema_version" = 1 ] || die "unsupported manifest schema"
manifest_version=$(manifest_string "$manifest_path" version)
manifest_tag=$(manifest_string "$manifest_path" tag)
is_semver "$manifest_version" || die "manifest contains an invalid version"
[ "$manifest_tag" = "v$manifest_version" ] || die "manifest tag does not match version"
if [ -n "$requested_version" ] && [ "$manifest_version" != "$requested_version" ]; then
    die "manifest version does not match requested version"
fi

asset_url=$(asset_string "$manifest_path" "$TARGET" url)
asset_sha256=$(asset_string "$manifest_path" "$TARGET" sha256)
asset_format=$(asset_string "$manifest_path" "$TARGET" format)
[ -n "$asset_url" ] && [ -n "$asset_sha256" ] && [ -n "$asset_format" ] \
    || die "manifest does not include target $TARGET"
require_https asset "$asset_url"
[ "$asset_format" = binary ] || die "manifest target $TARGET has unsupported format: $asset_format"
validate_digest "$asset_sha256"
asset_sha256=$(printf '%s\n' "$asset_sha256" | tr 'A-F' 'a-f')

install_dir=${FARPILOT_INSTALL_DIR:-$HOME/.local/bin}
target_path=$install_dir/$PROGRAM
if [ "$dry_run" -eq 1 ]; then
    log "dry run: would install FarPilot $manifest_version for $TARGET at $target_path"
    exit 0
fi

staged_path=$TMP/$PROGRAM
log "downloading FarPilot $manifest_version"
download "$asset_url" "$staged_path" || die "failed to download FarPilot binary"
actual_sha256=$(hash_file "$staged_path")
[ "$actual_sha256" = "$asset_sha256" ] || die "downloaded FarPilot checksum did not match"
chmod 755 "$staged_path"
reported_version=$($staged_path --version 2>/dev/null || true)
[ "$reported_version" = "farpilot $manifest_version" ] \
    || die "downloaded FarPilot reported version did not match manifest"

mkdir -p "$install_dir"
mv "$staged_path" "$target_path"
chmod 755 "$target_path"
log "installed FarPilot $manifest_version to $target_path"

case ":$PATH:" in
    *":$install_dir:"*) ;;
    *)
        warn "$install_dir is not in your PATH"
        printf '    export PATH="%s:$PATH"\n' "$install_dir"
        ;;
esac
log "ready. run 'farpilot --version'"
