#!/bin/sh
set -eu

PROGRAM=farpilot
DEFAULT_MANIFEST_URL=https://farpilot.polly.wang/latest.json
TMP=
LOCK_DIR=
LOCK_ACQUIRED=0
STAGED_DEST=
BACKUP_DEST=
ACTIVE_TARGET=

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
    if [ -n "$STAGED_DEST" ] && [ -f "$STAGED_DEST" ] && [ ! -L "$STAGED_DEST" ]; then
        rm -f "$STAGED_DEST"
    fi
    if [ -n "$BACKUP_DEST" ] && [ -f "$BACKUP_DEST" ] && [ ! -L "$BACKUP_DEST" ]; then
        if [ -n "$ACTIVE_TARGET" ] && [ ! -L "$ACTIVE_TARGET" ] && { [ ! -e "$ACTIVE_TARGET" ] || [ -f "$ACTIVE_TARGET" ]; }; then
            rm -f "$ACTIVE_TARGET"
            if mv "$BACKUP_DEST" "$ACTIVE_TARGET" 2>/dev/null; then
                BACKUP_DEST=
            fi
        fi
    fi
    if [ "$LOCK_ACQUIRED" -eq 1 ] && [ -n "$LOCK_DIR" ] && [ -d "$LOCK_DIR" ] && [ ! -L "$LOCK_DIR" ]; then
        rmdir "$LOCK_DIR" 2>/dev/null || true
    fi
    if [ -n "$TMP" ] && [ -d "$TMP" ] && [ ! -L "$TMP" ]; then
        rm -rf "$TMP"
    fi
}
trap cleanup EXIT
trap 'cleanup; exit 129' HUP
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

need() {
    command -v "$1" >/dev/null 2>&1 || die "requires '$1'"
}

is_semver() {
    semver_value=$1
    case "$semver_value" in
        ''|.*|*.|*..*|*[!0-9.]*) return 1 ;;
    esac
    semver_major=${semver_value%%.*}
    semver_rest=${semver_value#*.}
    [ "$semver_rest" != "$semver_value" ] || return 1
    semver_minor=${semver_rest%%.*}
    semver_patch=${semver_rest#*.}
    [ "$semver_patch" != "$semver_rest" ] || return 1
    case "$semver_patch" in *.*) return 1 ;; esac
    [ -n "$semver_major" ] && [ -n "$semver_minor" ] && [ -n "$semver_patch" ] || return 1
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

parse_gateway_installer() {
    manifest_file=$1
    awk '
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
        BEGIN { depth = 0 }
        {
            line = $0
            if (line ~ /^[[:space:]]*$/) next
            match(line, /[^ ]/)
            indent = RSTART ? RSTART - 1 : length(line)
            text = line
            sub(/^ */, "", text)
            if (NR == 1) {
                if (indent != 0 || text != "{") fail("manifest root must be an object")
                depth = 1
                next
            }
            if (root_closed) fail("content appears after manifest root")
            if (text ~ /^}[,]?[[:space:]]*$/) {
                if (depth < 1 || indent != 2 * (depth - 1)) fail("malformed object nesting")
                if (in_gateway && depth == gateway_depth) {
                    in_gateway = 0
                    gateway_depth = 0
                }
                if (in_installers && depth == installers_depth) {
                    in_installers = 0
                    installers_depth = 0
                }
                depth--
                if (depth == 0) {
                    if (text != "}") fail("manifest root must not have a trailing comma")
                    root_closed = 1
                }
                next
            }
            if (indent != 2 * depth) fail("malformed object nesting")
            if (text !~ /^"[^"]+"[[:space:]]*:/) fail("malformed object member")
            key = member_key(text)
            if (text ~ /^"[^"]+"[[:space:]]*:[[:space:]]*[{]$/) {
                if (depth == 1 && key == "installers") {
                    installers_count++
                    if (installers_count > 1) fail("duplicate top-level key: installers")
                    in_installers = 1
                    installers_depth = depth + 1
                } else if (in_installers && depth == installers_depth && key == "gateway") {
                    gateway_count++
                    if (gateway_count > 1) fail("duplicate installer key: gateway")
                    in_gateway = 1
                    gateway_depth = depth + 1
                }
                depth++
                next
            }
            if (depth == 1 && key == "schema_version") {
                schema_count++
                if (schema_count > 1) fail("duplicate top-level key: schema_version")
                if (text !~ /^"schema_version"[[:space:]]*:[[:space:]]*[0-9]+[[:space:]]*,?[[:space:]]*$/) fail("invalid top-level schema_version")
                schema = number_value(text)
            } else if (depth == 1 && key == "version") {
                version_count++
                if (version_count > 1) fail("duplicate top-level key: version")
                if (text !~ /^"version"[[:space:]]*:[[:space:]]*"[^"]*"[[:space:]]*,?[[:space:]]*$/) fail("invalid top-level version")
                version = string_value(text)
            } else if (depth == 1 && key == "tag") {
                tag_count++
                if (tag_count > 1) fail("duplicate top-level key: tag")
                if (text !~ /^"tag"[[:space:]]*:[[:space:]]*"[^"]*"[[:space:]]*,?[[:space:]]*$/) fail("invalid top-level tag")
                tag = string_value(text)
            } else if (depth == 1 && key == "installers") {
                installers_count++
                if (installers_count > 1) fail("duplicate top-level key: installers")
                if (text !~ /^"installers"[[:space:]]*:[[:space:]]*[{]}[[:space:]]*,?[[:space:]]*$/) fail("top-level installers must be an object")
            } else if (in_gateway && depth == gateway_depth && (key == "url" || key == "sha256")) {
                if (text !~ /^"[^"]+"[[:space:]]*:[[:space:]]*"[^"]*"[[:space:]]*,?[[:space:]]*$/) fail("invalid gateway installer field: " key)
                if (key == "url") {
                    url_count++
                    if (url_count > 1) fail("duplicate gateway installer field: url")
                    installer_url = string_value(text)
                } else {
                    sha_count++
                    if (sha_count > 1) fail("duplicate gateway installer field: sha256")
                    installer_sha = string_value(text)
                }
            }
        }
        END {
            if (failed) exit 1
            if (!root_closed || depth != 0) fail("unterminated manifest object")
            if (schema_count != 1) fail("manifest requires exactly one top-level schema_version")
            if (version_count != 1) fail("manifest requires exactly one top-level version")
            if (tag_count != 1) fail("manifest requires exactly one top-level tag")
            if (installers_count != 1) fail("manifest requires exactly one top-level installers object")
            if (gateway_count != 1) fail("manifest requires exactly one gateway installer")
            if (url_count != 1 || sha_count != 1) fail("gateway installer requires exactly one url and sha256")
            print schema
            print version
            print tag
            print installer_url
            print installer_sha
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
    digest_label=${2:-$TARGET}
    [ "${#digest_value}" -eq 64 ] || die "manifest contains an invalid SHA-256 for $digest_label"
    printf '%s\n' "$digest_value" | awk '/^[0-9A-Fa-f]+$/ { found=1 } END { exit(found ? 0 : 1) }' \
        || die "manifest contains an invalid SHA-256 for $digest_label"
}

validate_existing_target() {
    existing_target=$1
    if [ -L "$existing_target" ]; then
        die "refusing symlink install target: $existing_target"
    fi
    if [ -e "$existing_target" ] && [ ! -f "$existing_target" ]; then
        die "refusing non-regular install target: $existing_target"
    fi
}

acquire_lock() {
    LOCK_DIR=$1
    lock_retries=${FARPILOT_LOCK_RETRIES:-20}
    lock_delay=${FARPILOT_LOCK_DELAY:-1}
    case "$lock_retries" in ''|*[!0-9]*) die "FARPILOT_LOCK_RETRIES must be a nonnegative integer" ;; esac
    lock_attempt=0
    while ! mkdir "$LOCK_DIR" 2>/dev/null; do
        if [ "$lock_attempt" -ge "$lock_retries" ]; then
            die "another FarPilot installation is active: $LOCK_DIR"
        fi
        lock_attempt=$((lock_attempt + 1))
        sleep "$lock_delay"
    done
    LOCK_ACQUIRED=1
}

release_lock() {
    if [ "$LOCK_ACQUIRED" -eq 1 ]; then
        rmdir "$LOCK_DIR" || die "failed to release installation lock: $LOCK_DIR"
        LOCK_ACQUIRED=0
        LOCK_DIR=
    fi
}

restore_backup() {
    restore_target=$1
    if [ -n "$BACKUP_DEST" ] && [ -f "$BACKUP_DEST" ] && [ ! -L "$BACKUP_DEST" ]; then
        rm -f "$restore_target"
        if mv "$BACKUP_DEST" "$restore_target"; then
            BACKUP_DEST=
        else
            return 1
        fi
    fi
    return 0
}

activate_cli() {
    activate_downloaded=$1
    activate_version=$2
    activate_install_dir=$3
    activate_target=$4

    if [ -L "$activate_install_dir" ]; then
        die "refusing symlink install directory: $activate_install_dir"
    fi
    mkdir -p "$activate_install_dir"
    ACTIVE_TARGET=$activate_target
    acquire_lock "$activate_target.install.lock"
    validate_existing_target "$activate_target"

    if [ -f "$activate_target" ] && [ ! -L "$activate_target" ]; then
        existing_version=$("$activate_target" --version 2>/dev/null || true)
        if [ "$existing_version" = "farpilot $activate_version" ] && [ "$(hash_file "$activate_target")" = "$asset_sha256" ]; then
            log "FarPilot $activate_version is already installed at $activate_target"
            release_lock
            ACTIVE_TARGET=
            return 0
        fi
    fi

    STAGED_DEST=$activate_target.staged.$$
    BACKUP_DEST=$activate_target.backup.$$
    if [ -e "$STAGED_DEST" ] || [ -L "$STAGED_DEST" ] || [ -e "$BACKUP_DEST" ] || [ -L "$BACKUP_DEST" ]; then
        die "refusing pre-existing staging or backup path"
    fi
    cp "$activate_downloaded" "$STAGED_DEST"
    chmod 755 "$STAGED_DEST"
    [ "$(hash_file "$STAGED_DEST")" = "$asset_sha256" ] || die "staged FarPilot checksum did not match"

    activation_had_backup=0
    if [ -f "$activate_target" ]; then
        mv "$activate_target" "$BACKUP_DEST" || die "failed to back up existing FarPilot"
        activation_had_backup=1
    else
        BACKUP_DEST=
    fi
    if ! mv "$STAGED_DEST" "$activate_target"; then
        if [ ! -e "$STAGED_DEST" ] && [ ! -L "$STAGED_DEST" ]; then
            STAGED_DEST=
        fi
        restore_backup "$activate_target" || die "activation and rollback both failed"
        die "failed to activate FarPilot; previous version was restored"
    fi
    STAGED_DEST=
    installed_version=$("$activate_target" --version 2>/dev/null || true)
    if [ "$installed_version" != "farpilot $activate_version" ]; then
        rm -f "$activate_target"
        if [ "$activation_had_backup" -eq 1 ]; then
            if ! restore_backup "$activate_target"; then
                die "installed FarPilot verification failed and rollback failed"
            fi
            die "installed FarPilot verification failed; previous version was restored"
        fi
        BACKUP_DEST=
        die "installed FarPilot verification failed; incomplete install was removed"
    fi
    if [ -n "$BACKUP_DEST" ]; then
        rm -f "$BACKUP_DEST"
        BACKUP_DEST=
    fi
    release_lock
    ACTIVE_TARGET=
}

validate_manifest_header() {
    header_schema=$1
    header_version=$2
    header_tag=$3
    [ "$header_schema" = 1 ] || die "unsupported manifest schema"
    is_semver "$header_version" || die "manifest contains an invalid version"
    [ "$header_tag" = "v$header_version" ] || die "manifest tag does not match version"
    if [ -n "$requested_version" ] && [ "$header_version" != "$requested_version" ]; then
        die "manifest version does not match requested version"
    fi
}

parse_gateway_options() {
    gateway_has_version=0
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --version)
                [ "$#" -ge 2 ] || die "--version requires a value"
                gateway_version=$(normalize_version "$2")
                if [ -n "$requested_version" ] && [ "$requested_version" != "$gateway_version" ]; then
                    die "conflicting --version values"
                fi
                requested_version=$gateway_version
                gateway_has_version=1
                shift 2
                ;;
            --dry-run)
                dry_run=1
                shift
                ;;
            --domain|--email)
                [ "$#" -ge 2 ] || die "$1 requires a value"
                shift 2
                ;;
            --)
                shift
                [ "$#" -eq 0 ] || die "unexpected Gateway positional argument: $1"
                ;;
            *) die "unknown Gateway argument: $1" ;;
        esac
    done
}

role=cli
requested_version=
dry_run=0
gateway_pre_version=
gateway_has_version=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        gateway)
            role=gateway
            gateway_pre_version=$requested_version
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
    parse_gateway_options "$@"
else
    [ "$#" -eq 0 ] || die "unexpected positional argument: $1"
fi

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
install_dir=${FARPILOT_INSTALL_DIR:-$HOME/.local/bin}
target_path=$install_dir/$PROGRAM

if [ "$role" = gateway ]; then
    if ! parse_gateway_installer "$manifest_path" > "$parsed_manifest"; then
        die "invalid release manifest"
    fi
    schema_version=$(awk 'NR == 1 { print; exit }' "$parsed_manifest")
    manifest_version=$(awk 'NR == 2 { print; exit }' "$parsed_manifest")
    manifest_tag=$(awk 'NR == 3 { print; exit }' "$parsed_manifest")
    gateway_url=$(awk 'NR == 4 { print; exit }' "$parsed_manifest")
    gateway_sha256=$(awk 'NR == 5 { print; exit }' "$parsed_manifest")
    validate_manifest_header "$schema_version" "$manifest_version" "$manifest_tag"
    require_https "Gateway installer" "$gateway_url"
    validate_digest "$gateway_sha256" "Gateway installer"
    gateway_sha256=$(printf '%s\n' "$gateway_sha256" | tr 'A-F' 'a-f')

    if [ "$dry_run" -eq 1 ]; then
        log "dry run"
        log "role: gateway"
        log "target: $TARGET"
        log "manifest: $MANIFEST_URL"
        log "version: $manifest_version"
        log "installer: $gateway_url"
        exit 0
    fi

    gateway_script=$TMP/install-gateway.sh
    log "downloading Gateway installer $manifest_version"
    download "$gateway_url" "$gateway_script" || die "failed to download Gateway installer"
    actual_gateway_sha256=$(hash_file "$gateway_script")
    [ "$actual_gateway_sha256" = "$gateway_sha256" ] || die "Gateway installer checksum did not match"
    if [ -n "$gateway_pre_version" ] && [ "$gateway_has_version" -eq 0 ]; then
        sh "$gateway_script" --manifest "$manifest_path" "$@" --version "v$requested_version"
    else
        sh "$gateway_script" --manifest "$manifest_path" "$@"
    fi
    exit $?
fi

if ! parse_manifest "$manifest_path" "$TARGET" > "$parsed_manifest"; then
    die "invalid release manifest"
fi
schema_version=$(awk 'NR == 1 { print; exit }' "$parsed_manifest")
manifest_version=$(awk 'NR == 2 { print; exit }' "$parsed_manifest")
manifest_tag=$(awk 'NR == 3 { print; exit }' "$parsed_manifest")
asset_url=$(awk 'NR == 4 { print; exit }' "$parsed_manifest")
asset_sha256=$(awk 'NR == 5 { print; exit }' "$parsed_manifest")
asset_format=$(awk 'NR == 6 { print; exit }' "$parsed_manifest")
validate_manifest_header "$schema_version" "$manifest_version" "$manifest_tag"
require_https asset "$asset_url"
[ "$asset_format" = binary ] || die "manifest target $TARGET has unsupported format: $asset_format"
validate_digest "$asset_sha256" "$TARGET"
asset_sha256=$(printf '%s\n' "$asset_sha256" | tr 'A-F' 'a-f')

if [ "$dry_run" -eq 1 ]; then
    log "dry run"
    log "role: cli"
    log "target: $TARGET"
    log "manifest: $MANIFEST_URL"
    log "version: $manifest_version"
    log "asset: $asset_url"
    log "destination: $target_path"
    exit 0
fi

staged_path=$TMP/$PROGRAM
log "downloading FarPilot $manifest_version"
download "$asset_url" "$staged_path" || die "failed to download FarPilot binary"
actual_sha256=$(hash_file "$staged_path")
[ "$actual_sha256" = "$asset_sha256" ] || die "downloaded FarPilot checksum did not match"
chmod 755 "$staged_path"
reported_version=$("$staged_path" --version 2>/dev/null || true)
[ "$reported_version" = "farpilot $manifest_version" ] \
    || die "downloaded FarPilot reported version did not match manifest"

activate_cli "$staged_path" "$manifest_version" "$install_dir" "$target_path"
log "installed FarPilot $manifest_version to $target_path"

case ":$PATH:" in
    *":$install_dir:"*) ;;
    *)
        warn "$install_dir is not in your PATH"
        printf '    export PATH="%s:%s"\n' "$install_dir" '$PATH'
        ;;
esac
log "ready. run 'farpilot --version'"
