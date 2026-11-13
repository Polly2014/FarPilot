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

parse_manifest() {
    manifest_file=$1
    asset_target=$2
    awk -v selected_target="$asset_target" '
        function fail(message) {
            print "manifest parse error: " message > "/dev/stderr"
            failed = 1
            exit 1
        }
        function member_key(text, value) {
            value = text
            sub(/^"/, "", value)
            sub(/".*/, "", value)
            return value
        }
        function string_value(text, value) {
            value = text
            sub(/^[^:]*:[[:space:]]*"/, "", value)
            sub(/"[[:space:]]*,?[[:space:]]*$/, "", value)
            return value
        }
        function number_value(text, value) {
            value = text
            sub(/^[^:]*:[[:space:]]*/, "", value)
            sub(/[[:space:]]*,?[[:space:]]*$/, "", value)
            return value
        }
        BEGIN {
            depth = 0
        }
        {
            line = $0
            if (line ~ /^[[:space:]]*$/) {
                next
            }
            match(line, /[^ ]/)
            indent = RSTART ? RSTART - 1 : length(line)
            text = line
            sub(/^ */, "", text)

            if (NR == 1) {
                if (indent != 0 || text != "{") {
                    fail("manifest root must be an object")
                }
                depth = 1
                next
            }
            if (root_closed) {
                fail("content appears after manifest root")
            }

            if (text ~ /^}[,]?[[:space:]]*$/) {
                if (depth < 1 || indent != 2 * (depth - 1)) {
                    fail("malformed object nesting")
                }
                if (in_target && depth == target_depth) {
                    in_target = 0
                    target_depth = 0
                }
                if (in_assets && depth == assets_depth) {
                    in_assets = 0
                    assets_depth = 0
                }
                depth--
                if (depth == 0) {
                    if (text != "}") {
                        fail("manifest root must not have a trailing comma")
                    }
                    root_closed = 1
                }
                next
            }

            if (indent != 2 * depth) {
                fail("malformed object nesting")
            }
            if (text !~ /^"[^"]+"[[:space:]]*:/) {
                fail("malformed object member")
            }
            key = member_key(text)

            if (text ~ /^"[^"]+"[[:space:]]*:[[:space:]]*[{]$/) {
                if (depth == 1 && key == "assets") {
                    assets_count++
                    if (assets_count > 1) {
                        fail("duplicate top-level key: assets")
                    }
                    in_assets = 1
                    assets_depth = depth + 1
                } else if (in_assets && depth == assets_depth && key == selected_target) {
                    target_count++
                    if (target_count > 1) {
                        fail("duplicate target key: " selected_target)
                    }
                    in_target = 1
                    target_depth = depth + 1
                }
                depth++
                next
            }

            if (depth == 1 && key == "schema_version") {
                schema_count++
                if (schema_count > 1) {
                    fail("duplicate top-level key: schema_version")
                }
                if (text !~ /^"schema_version"[[:space:]]*:[[:space:]]*[0-9]+[[:space:]]*,?[[:space:]]*$/) {
                    fail("invalid top-level schema_version")
                }
                schema = number_value(text)
            } else if (depth == 1 && key == "version") {
                version_count++
                if (version_count > 1) {
                    fail("duplicate top-level key: version")
                }
                if (text !~ /^"version"[[:space:]]*:[[:space:]]*"[^"]*"[[:space:]]*,?[[:space:]]*$/) {
                    fail("invalid top-level version")
                }
                version = string_value(text)
            } else if (depth == 1 && key == "tag") {
                tag_count++
                if (tag_count > 1) {
                    fail("duplicate top-level key: tag")
                }
                if (text !~ /^"tag"[[:space:]]*:[[:space:]]*"[^"]*"[[:space:]]*,?[[:space:]]*$/) {
                    fail("invalid top-level tag")
                }
                tag = string_value(text)
            } else if (depth == 1 && key == "assets") {
                assets_count++
                if (assets_count > 1) {
                    fail("duplicate top-level key: assets")
                }
                if (text !~ /^"assets"[[:space:]]*:[[:space:]]*[{]}[[:space:]]*,?[[:space:]]*$/) {
                    fail("top-level assets must be an object")
                }
            } else if (in_target && depth == target_depth && (key == "url" || key == "sha256" || key == "format")) {
                if (text !~ /^"[^"]+"[[:space:]]*:[[:space:]]*"[^"]*"[[:space:]]*,?[[:space:]]*$/) {
                    fail("invalid selected target field: " key)
                }
                if (key == "url") {
                    url_count++
                    if (url_count > 1) fail("duplicate target field: url")
                    asset_url = string_value(text)
                } else if (key == "sha256") {
                    sha_count++
                    if (sha_count > 1) fail("duplicate target field: sha256")
                    asset_sha = string_value(text)
                } else {
                    format_count++
                    if (format_count > 1) fail("duplicate target field: format")
                    asset_format = string_value(text)
                }
            }
        }
        END {
            if (failed) exit 1
            if (!root_closed || depth != 0) fail("unterminated manifest object")
            if (schema_count != 1) fail("manifest requires exactly one top-level schema_version")
            if (version_count != 1) fail("manifest requires exactly one top-level version")
            if (tag_count != 1) fail("manifest requires exactly one top-level tag")
            if (assets_count != 1) fail("manifest requires exactly one top-level assets object")
            if (target_count != 1) fail("manifest does not include target " selected_target)
            if (url_count != 1 || sha_count != 1 || format_count != 1) {
                fail("selected target requires exactly one url, sha256, and format")
            }
            print schema
            print version
            print tag
            print asset_url
            print asset_sha
            print asset_format
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

parsed_manifest=$TMP/manifest.parsed
if ! parse_manifest "$manifest_path" "$TARGET" > "$parsed_manifest"; then
    die "invalid release manifest"
fi
schema_version=$(awk 'NR == 1 { print; exit }' "$parsed_manifest")
manifest_version=$(awk 'NR == 2 { print; exit }' "$parsed_manifest")
manifest_tag=$(awk 'NR == 3 { print; exit }' "$parsed_manifest")
asset_url=$(awk 'NR == 4 { print; exit }' "$parsed_manifest")
asset_sha256=$(awk 'NR == 5 { print; exit }' "$parsed_manifest")
asset_format=$(awk 'NR == 6 { print; exit }' "$parsed_manifest")
[ "$schema_version" = 1 ] || die "unsupported manifest schema"
is_semver "$manifest_version" || die "manifest contains an invalid version"
[ "$manifest_tag" = "v$manifest_version" ] || die "manifest tag does not match version"
if [ -n "$requested_version" ] && [ "$manifest_version" != "$requested_version" ]; then
    die "manifest version does not match requested version"
fi

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
