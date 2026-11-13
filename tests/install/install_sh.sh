#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

fail() {
    printf '%s\n' "FAIL: $1" >&2
    exit 1
}

assert_status() {
    expected=$1
    [ "$STATUS" -eq "$expected" ] || {
        printf '%s\n' "stdout:" >&2
        cat "$CASE/stdout" >&2 || true
        printf '%s\n' "stderr:" >&2
        cat "$CASE/stderr" >&2 || true
        fail "expected status $expected, got $STATUS"
    }
}

assert_failure() {
    [ "$STATUS" -ne 0 ] || fail "expected command to fail"
}

assert_contains() {
    file=$1
    value=$2
    if ! grep -Fq -- "$value" "$file"; then
        printf '%s\n' "contents of $file:" >&2
        cat "$file" >&2 || true
        fail "expected '$value' in $file"
    fi
}

assert_absent() {
    [ ! -e "$1" ] && [ ! -L "$1" ] || fail "expected path to be absent: $1"
}

assert_not_contains() {
    file=$1
    value=$2
    if grep -Fq -- "$value" "$file"; then
        fail "did not expect '$value' in $file"
    fi
}

hash_file() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print tolower($1)}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print tolower($1)}'
    else
        openssl dgst -sha256 "$1" | awk '{print tolower($NF)}'
    fi
}

inode_of() {
    if stat -f '%i' "$1" >/dev/null 2>&1; then
        stat -f '%i' "$1"
    else
        stat -c '%i' "$1"
    fi
}

assert_no_managed_artifacts() {
    directory=$1
    [ -d "$directory" ] || return 0
    artifacts=$(find "$directory" -maxdepth 1 \( -name 'farpilot.staged.*' -o -name 'farpilot.backup.*' -o -name 'farpilot.install.lock' \) -print)
    [ -z "$artifacts" ] || fail "managed artifacts remain: $artifacts"
}

mkdir -p "$tmp/shared-downloads"
for name in \
    farpilot-macos-aarch64 \
    farpilot-macos-x86_64 \
    farpilot-linux-aarch64 \
    farpilot-linux-x86_64
do
    cp "$root/tests/fixtures/install/farpilot-fixture.sh" "$tmp/shared-downloads/$name"
done
chmod +x "$tmp/shared-downloads"/farpilot-*
good_sha=$(hash_file "$tmp/shared-downloads/farpilot-macos-aarch64")

cat > "$tmp/bad-version.sh" <<'EOF'
#!/bin/sh
if [ "${1:-}" = "--version" ]; then
    printf '%s\n' 'farpilot 9.8.6'
    exit 0
fi
exit 0
EOF
chmod +x "$tmp/bad-version.sh"

cat > "$tmp/old-version.sh" <<'EOF'
#!/bin/sh
if [ "${1:-}" = "--version" ]; then
    printf '%s\n' 'farpilot 9.8.6'
    exit 0
fi
exit 0
EOF
chmod +x "$tmp/old-version.sh"

cat > "$tmp/gateway-installer.sh" <<'EOF'
#!/bin/sh
set -eu
[ -n "${FARPILOT_TEST_GATEWAY_LOG:-}" ] || exit 91
[ "${1:-}" = "--manifest" ] || exit 92
[ -f "${2:-}" ] && [ ! -L "${2:-}" ] || exit 93
printf '%s\n' "$@" > "$FARPILOT_TEST_GATEWAY_LOG"
EOF
chmod +x "$tmp/gateway-installer.sh"
gateway_sha=$(hash_file "$tmp/gateway-installer.sh")

write_manifest() {
    destination=$1
    version=$2
    tag=$3
    digest=$4
    mac_arm_name=${5:-farpilot-macos-aarch64}
    cat > "$destination" <<EOF
{
  "assets": {
    "linux-aarch64": {
      "format": "binary",
      "sha256": "$digest",
      "url": "https://downloads.example/farpilot-linux-aarch64"
    },
    "linux-x86_64": {
      "format": "binary",
      "sha256": "$digest",
      "url": "https://downloads.example/farpilot-linux-x86_64"
    },
    "macos-aarch64": {
      "format": "binary",
      "sha256": "$digest",
      "url": "https://downloads.example/$mac_arm_name"
    },
    "macos-x86_64": {
      "format": "binary",
      "sha256": "$digest",
      "url": "https://downloads.example/farpilot-macos-x86_64"
    }
  },
  "installers": {
    "gateway": {
      "sha256": "$gateway_sha",
      "url": "https://downloads.example/install-gateway.sh"
    }
  },
  "schema_version": 1,
  "tag": "$tag",
  "version": "$version"
}
EOF
}

new_case() {
    name=$1
    CASE=$tmp/$name
    rm -rf "$CASE"
    mkdir -p "$CASE/bin" "$CASE/downloads" "$CASE/home"
    cp "$root/tests/fixtures/install/fake-curl.sh" "$CASE/bin/curl"
    chmod +x "$CASE/bin/curl"
    cp "$tmp/shared-downloads"/farpilot-* "$CASE/downloads/"
    cp "$tmp/gateway-installer.sh" "$CASE/downloads/install-gateway.sh"
    : > "$CASE/curl.log"
}

run_install() {
    os=$1
    arch=$2
    uname_o=$3
    manifest_url=$4
    shift 4
    case_install_dir=${FARPILOT_TEST_INSTALL_DIR:-$CASE/home/install-bin}
    set +e
    if [ "$manifest_url" = DEFAULT ]; then
        env \
            FARPILOT_TEST_DOWNLOADS="$CASE/downloads" \
            FARPILOT_TEST_CURL_LOG="$CASE/curl.log" \
            FARPILOT_UNAME_S="$os" \
            FARPILOT_UNAME_M="$arch" \
            FARPILOT_UNAME_O="$uname_o" \
            FARPILOT_INSTALL_DIR="$case_install_dir" \
            HOME="$CASE/home" \
            PATH="$CASE/bin:/usr/bin:/bin" \
            sh "$root/install.sh" "$@" >"$CASE/stdout" 2>"$CASE/stderr"
    else
        env \
            FARPILOT_TEST_DOWNLOADS="$CASE/downloads" \
            FARPILOT_TEST_CURL_LOG="$CASE/curl.log" \
            FARPILOT_UNAME_S="$os" \
            FARPILOT_UNAME_M="$arch" \
            FARPILOT_UNAME_O="$uname_o" \
            FARPILOT_MANIFEST_URL="$manifest_url" \
            FARPILOT_INSTALL_DIR="$case_install_dir" \
            HOME="$CASE/home" \
            PATH="$CASE/bin:/usr/bin:/bin" \
            sh "$root/install.sh" "$@" >"$CASE/stdout" 2>"$CASE/stderr"
    fi
    STATUS=$?
    set -e
}

# Darwin arm64 installs a verified executable and does not edit shell profiles.
new_case darwin-arm
write_manifest "$CASE/downloads/latest.json" 9.8.7 v9.8.7 "$good_sha"
printf '%s\n' 'original profile' > "$CASE/home/.zprofile"
profile_before=$(hash_file "$CASE/home/.zprofile")
run_install Darwin arm64 '' https://downloads.example/latest.json
assert_status 0
[ -x "$CASE/home/install-bin/farpilot" ] || fail "installed binary is not executable"
[ "$("$CASE/home/install-bin/farpilot" --version)" = 'farpilot 9.8.7' ] || fail "installed version is wrong"
assert_contains "$CASE/curl.log" 'https://downloads.example/farpilot-macos-aarch64'
assert_contains "$CASE/stdout" "export PATH=\"$CASE/home/install-bin:\$PATH\""
[ "$(hash_file "$CASE/home/.zprofile")" = "$profile_before" ] || fail "installer changed .zprofile"

# Every supported Unix mapping selects the exact target asset.
for row in \
    'Darwin x86_64 farpilot-macos-x86_64' \
    'Linux x86_64 farpilot-linux-x86_64' \
    'Linux aarch64 farpilot-linux-aarch64'
do
    set -- $row
    os=$1
    arch=$2
    asset=$3
    new_case "mapping-$os-$arch"
    write_manifest "$CASE/downloads/latest.json" 9.8.7 v9.8.7 "$good_sha"
    run_install "$os" "$arch" '' https://downloads.example/latest.json
    assert_status 0
    assert_contains "$CASE/curl.log" "https://downloads.example/$asset"
done

# Unsupported systems and Android fail before even fetching a manifest.
new_case unsupported-os
run_install Plan9 x86_64 '' https://downloads.example/latest.json
assert_failure
assert_contains "$CASE/stderr" 'unsupported OS'
[ ! -s "$CASE/curl.log" ] || fail "unsupported OS performed a download"

new_case unsupported-arch
run_install Darwin riscv64 '' https://downloads.example/latest.json
assert_failure
assert_contains "$CASE/stderr" 'unsupported architecture'
[ ! -s "$CASE/curl.log" ] || fail "unsupported architecture performed a download"

new_case android
run_install Linux aarch64 Android https://downloads.example/latest.json
assert_failure
assert_contains "$CASE/stderr" 'Android/Termux is not supported'
[ ! -s "$CASE/curl.log" ] || fail "Android performed a download"

# The manifest itself must use HTTPS.
new_case http-manifest
run_install Darwin arm64 '' http://downloads.example/latest.json
assert_failure
assert_contains "$CASE/stderr" 'manifest URL must use HTTPS'
[ ! -s "$CASE/curl.log" ] || fail "HTTP manifest was downloaded"

# A missing selected target fails without installing.
new_case missing-target
cat > "$CASE/downloads/latest.json" <<EOF
{
  "assets": {},
  "installers": {},
  "schema_version": 1,
  "tag": "v9.8.7",
  "version": "9.8.7"
}
EOF
run_install Darwin arm64 '' https://downloads.example/latest.json
assert_failure
assert_contains "$CASE/stderr" 'manifest does not include target macos-aarch64'
assert_absent "$CASE/home/install-bin/farpilot"

# Malformed and mismatched digests fail before activation.
new_case short-digest
write_manifest "$CASE/downloads/latest.json" 9.8.7 v9.8.7 abc123
run_install Darwin arm64 '' https://downloads.example/latest.json
assert_failure
assert_contains "$CASE/stderr" 'invalid SHA-256'
assert_absent "$CASE/home/install-bin/farpilot"

new_case nonhex-digest
write_manifest "$CASE/downloads/latest.json" 9.8.7 v9.8.7 gggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggg
run_install Darwin arm64 '' https://downloads.example/latest.json
assert_failure
assert_contains "$CASE/stderr" 'invalid SHA-256'
assert_absent "$CASE/home/install-bin/farpilot"

new_case checksum-mismatch
write_manifest "$CASE/downloads/latest.json" 9.8.7 v9.8.7 0000000000000000000000000000000000000000000000000000000000000000
run_install Darwin arm64 '' https://downloads.example/latest.json
assert_failure
assert_contains "$CASE/stderr" 'checksum did not match'
assert_absent "$CASE/home/install-bin/farpilot"

# A staged binary that reports another version is never activated.
new_case version-mismatch
cp "$tmp/bad-version.sh" "$CASE/downloads/farpilot-macos-aarch64"
bad_sha=$(hash_file "$CASE/downloads/farpilot-macos-aarch64")
write_manifest "$CASE/downloads/latest.json" 9.8.7 v9.8.7 "$bad_sha"
run_install Darwin arm64 '' https://downloads.example/latest.json
assert_failure
assert_contains "$CASE/stderr" 'reported version did not match manifest'
assert_absent "$CASE/home/install-bin/farpilot"

# Default latest and both pinned syntaxes resolve exact manifest URLs.
new_case latest-url
write_manifest "$CASE/downloads/latest.json" 9.8.7 v9.8.7 "$good_sha"
run_install Darwin arm64 '' DEFAULT
assert_status 0
assert_contains "$CASE/curl.log" 'https://farpilot.polly.wang/latest.json'

for requested in v9.8.7 9.8.7; do
    new_case "pinned-$requested"
    write_manifest "$CASE/downloads/manifest.json" 9.8.7 v9.8.7 "$good_sha"
    run_install Darwin arm64 '' DEFAULT --version "$requested"
    assert_status 0
    assert_contains "$CASE/curl.log" 'https://github.com/Polly2014/FarPilot/releases/download/v9.8.7/manifest.json'
done

# Invalid arguments fail closed.
new_case unknown-arg
run_install Darwin arm64 '' DEFAULT --become-root
assert_failure
assert_contains "$CASE/stderr" 'unknown argument'

new_case missing-version-value
run_install Darwin arm64 '' DEFAULT --version
assert_failure
assert_contains "$CASE/stderr" '--version requires a value'

new_case invalid-version
run_install Darwin arm64 '' DEFAULT --version release/latest
assert_failure
assert_contains "$CASE/stderr" 'version must use X.Y.Z'

# The fake downloader itself rejects symlink fixtures and encoded separators.
new_case symlink-fixture
ln -s "$tmp/shared-downloads/farpilot-macos-aarch64" "$CASE/downloads/linked"
write_manifest "$CASE/downloads/latest.json" 9.8.7 v9.8.7 "$good_sha" linked
run_install Darwin arm64 '' https://downloads.example/latest.json
assert_failure
assert_contains "$CASE/stderr" 'fixture is missing or unsafe'
assert_absent "$CASE/home/install-bin/farpilot"

new_case encoded-separator
write_manifest "$CASE/downloads/latest.json" 9.8.7 v9.8.7 "$good_sha" 'bad%2fname'
run_install Darwin arm64 '' https://downloads.example/latest.json
assert_failure
assert_contains "$CASE/stderr" 'unsafe URL basename'
assert_absent "$CASE/home/install-bin/farpilot"

# A valid-looking target under an earlier shadow object must never override assets.
new_case shadow-object
cp "$tmp/shared-downloads/farpilot-macos-aarch64" "$CASE/downloads/shadow-binary"
cat > "$CASE/downloads/latest.json" <<EOF
{
  "shadow": {
    "macos-aarch64": {
      "format": "binary",
      "sha256": "0000000000000000000000000000000000000000000000000000000000000000",
      "url": "https://downloads.example/shadow-binary"
    }
  },
  "assets": {
    "macos-aarch64": {
      "format": "binary",
      "sha256": "$good_sha",
      "url": "https://downloads.example/farpilot-macos-aarch64"
    }
  },
  "installers": {},
  "schema_version": 1,
  "tag": "v9.8.7",
  "version": "9.8.7"
}
EOF
run_install Darwin arm64 '' https://downloads.example/latest.json
assert_status 0
assert_contains "$CASE/curl.log" 'https://downloads.example/farpilot-macos-aarch64'
assert_not_contains "$CASE/curl.log" 'https://downloads.example/shadow-binary'

# Duplicate top-level version keys fail closed before artifact download.
new_case duplicate-version
cat > "$CASE/downloads/latest.json" <<EOF
{
  "assets": {
    "macos-aarch64": {
      "format": "binary",
      "sha256": "$good_sha",
      "url": "https://downloads.example/farpilot-macos-aarch64"
    }
  },
  "installers": {},
  "schema_version": 1,
  "tag": "v9.8.7",
  "version": "9.8.7",
  "version": "9.8.7"
}
EOF
run_install Darwin arm64 '' https://downloads.example/latest.json
assert_failure
assert_contains "$CASE/stderr" 'duplicate top-level key: version'
assert_not_contains "$CASE/curl.log" 'farpilot-macos-aarch64'

# Duplicate top-level schema_version and tag keys fail closed.
for duplicate_top_key in schema_version tag; do
    new_case "duplicate-$duplicate_top_key"
    case "$duplicate_top_key" in
        schema_version)
            duplicate_top_line='  "schema_version": 1,'
            ;;
        tag)
            duplicate_top_line='  "tag": "v9.8.7",'
            ;;
    esac
    cat > "$CASE/downloads/latest.json" <<EOF
{
  "assets": {
    "macos-aarch64": {
      "format": "binary",
      "sha256": "$good_sha",
      "url": "https://downloads.example/farpilot-macos-aarch64"
    }
  },
  "installers": {},
  "schema_version": 1,
$duplicate_top_line
  "tag": "v9.8.7",
  "version": "9.8.7"
}
EOF
    run_install Darwin arm64 '' https://downloads.example/latest.json
    assert_failure
    assert_contains "$CASE/stderr" "duplicate top-level key: $duplicate_top_key"
done

# Duplicate top-level assets objects fail closed.
new_case duplicate-assets
cat > "$CASE/downloads/latest.json" <<EOF
{
  "assets": {
    "macos-aarch64": {
      "format": "binary",
      "sha256": "$good_sha",
      "url": "https://downloads.example/farpilot-macos-aarch64"
    }
  },
  "assets": {
    "macos-aarch64": {
      "format": "binary",
      "sha256": "$good_sha",
      "url": "https://downloads.example/farpilot-macos-aarch64"
    }
  },
  "installers": {},
  "schema_version": 1,
  "tag": "v9.8.7",
  "version": "9.8.7"
}
EOF
run_install Darwin arm64 '' https://downloads.example/latest.json
assert_failure
assert_contains "$CASE/stderr" 'duplicate top-level key: assets'

# Duplicate target keys in the one assets object fail closed.
new_case duplicate-target
cat > "$CASE/downloads/latest.json" <<EOF
{
  "assets": {
    "macos-aarch64": {
      "format": "binary",
      "sha256": "$good_sha",
      "url": "https://downloads.example/farpilot-macos-aarch64"
    },
    "macos-aarch64": {
      "format": "binary",
      "sha256": "$good_sha",
      "url": "https://downloads.example/farpilot-macos-aarch64"
    }
  },
  "installers": {},
  "schema_version": 1,
  "tag": "v9.8.7",
  "version": "9.8.7"
}
EOF
run_install Darwin arm64 '' https://downloads.example/latest.json
assert_failure
assert_contains "$CASE/stderr" 'duplicate target key: macos-aarch64'

# Duplicate selected target fields fail closed.
for duplicate_field in url sha256 format; do
    new_case "duplicate-field-$duplicate_field"
    case "$duplicate_field" in
        url)
            duplicate_line='      "url": "https://downloads.example/farpilot-macos-aarch64",'
            ;;
        sha256)
            duplicate_line="      \"sha256\": \"$good_sha\","
            ;;
        format)
            duplicate_line='      "format": "binary",'
            ;;
    esac
    cat > "$CASE/downloads/latest.json" <<EOF
{
  "assets": {
    "macos-aarch64": {
      "format": "binary",
      "sha256": "$good_sha",
      "url": "https://downloads.example/farpilot-macos-aarch64",
$duplicate_line
      "unused": "value"
    }
  },
  "installers": {},
  "schema_version": 1,
  "tag": "v9.8.7",
  "version": "9.8.7"
}
EOF
    run_install Darwin arm64 '' https://downloads.example/latest.json
    assert_failure
    assert_contains "$CASE/stderr" "duplicate target field: $duplicate_field"
done

# Malformed indentation/nesting fails closed rather than searching another object.
new_case malformed-nesting
cat > "$CASE/downloads/latest.json" <<EOF
{
  "assets": {
  "macos-aarch64": {
      "format": "binary",
      "sha256": "$good_sha",
      "url": "https://downloads.example/farpilot-macos-aarch64"
    }
  },
  "installers": {},
  "schema_version": 1,
  "tag": "v9.8.7",
  "version": "9.8.7"
}
EOF
run_install Darwin arm64 '' https://downloads.example/latest.json
assert_failure
assert_contains "$CASE/stderr" 'malformed object nesting'

# Exact-key parsing ignores substring keys at every relevant nesting level.
new_case substring-keys
cat > "$CASE/downloads/latest.json" <<EOF
{
  "notversion": "0.0.0",
  "assets": {
    "macos-aarch64-extra": {
      "format": "binary",
      "sha256": "0000000000000000000000000000000000000000000000000000000000000000",
      "url": "https://downloads.example/shadow-binary"
    },
    "macos-aarch64": {
      "download_url": "https://downloads.example/shadow-binary",
      "format": "binary",
      "sha256": "$good_sha",
      "url": "https://downloads.example/farpilot-macos-aarch64"
    }
  },
  "installers": {},
  "schema_version": 1,
  "tag": "v9.8.7",
  "version": "9.8.7"
}
EOF
run_install Darwin arm64 '' https://downloads.example/latest.json
assert_status 0
assert_contains "$CASE/curl.log" 'https://downloads.example/farpilot-macos-aarch64'
assert_not_contains "$CASE/curl.log" 'https://downloads.example/shadow-binary'

# Existing installations upgrade atomically and leave no managed artifacts.
new_case atomic-upgrade
write_manifest "$CASE/downloads/latest.json" 9.8.7 v9.8.7 "$good_sha"
mkdir -p "$CASE/home/install-bin"
cp "$tmp/old-version.sh" "$CASE/home/install-bin/farpilot"
chmod +x "$CASE/home/install-bin/farpilot"
old_inode=$(inode_of "$CASE/home/install-bin/farpilot")
run_install Darwin arm64 '' https://downloads.example/latest.json
assert_status 0
[ "$("$CASE/home/install-bin/farpilot" --version)" = 'farpilot 9.8.7' ] || fail "upgrade did not activate new version"
[ "$(inode_of "$CASE/home/install-bin/farpilot")" != "$old_inode" ] || fail "upgrade did not replace inode"
assert_no_managed_artifacts "$CASE/home/install-bin"

# Reinstalling the current exact version is idempotent and preserves the inode.
new_case current-version-idempotent
write_manifest "$CASE/downloads/latest.json" 9.8.7 v9.8.7 "$good_sha"
mkdir -p "$CASE/home/install-bin"
cp "$tmp/shared-downloads/farpilot-macos-aarch64" "$CASE/home/install-bin/farpilot"
chmod +x "$CASE/home/install-bin/farpilot"
current_inode=$(inode_of "$CASE/home/install-bin/farpilot")
current_hash=$(hash_file "$CASE/home/install-bin/farpilot")
run_install Darwin arm64 '' https://downloads.example/latest.json
assert_status 0
[ "$(inode_of "$CASE/home/install-bin/farpilot")" = "$current_inode" ] || fail "same-version install replaced inode"
[ "$(hash_file "$CASE/home/install-bin/farpilot")" = "$current_hash" ] || fail "same-version install changed bytes"
assert_no_managed_artifacts "$CASE/home/install-bin"

# Install directories containing spaces support install, idempotence, and rollback.
new_case install-dir-spaces
write_manifest "$CASE/downloads/latest.json" 9.8.7 v9.8.7 "$good_sha"
space_install_dir="$CASE/home/FarPilot Programs/bin"
export FARPILOT_TEST_INSTALL_DIR="$space_install_dir"
run_install Darwin arm64 '' https://downloads.example/latest.json
assert_status 0
[ "$("$space_install_dir/farpilot" --version)" = 'farpilot 9.8.7' ] || fail "space-path first install failed"
space_inode=$(inode_of "$space_install_dir/farpilot")
space_hash=$(hash_file "$space_install_dir/farpilot")
run_install Darwin arm64 '' https://downloads.example/latest.json
assert_status 0
[ "$(inode_of "$space_install_dir/farpilot")" = "$space_inode" ] || fail "space-path same-version install replaced inode"
[ "$(hash_file "$space_install_dir/farpilot")" = "$space_hash" ] || fail "space-path same-version install changed bytes"
printf '%s\n' '# force a verified replacement attempt' >> "$space_install_dir/farpilot"
space_rollback_inode=$(inode_of "$space_install_dir/farpilot")
space_rollback_hash=$(hash_file "$space_install_dir/farpilot")
cat > "$CASE/bin/mv" <<'EOF'
#!/bin/sh
set -eu
source_path=$1
destination=$2
/bin/mv "$source_path" "$destination"
case "$source_path:$destination:${FARPILOT_TEST_CORRUPT_ACTIVATED:-0}" in
    *.staged.*:*/farpilot:1)
        printf '%s\n' '#!/bin/sh' 'exit 47' > "$destination"
        chmod +x "$destination"
        ;;
esac
EOF
chmod +x "$CASE/bin/mv"
export FARPILOT_TEST_CORRUPT_ACTIVATED=1
run_install Darwin arm64 '' https://downloads.example/latest.json
unset FARPILOT_TEST_CORRUPT_ACTIVATED FARPILOT_TEST_INSTALL_DIR
assert_failure
[ "$(inode_of "$space_install_dir/farpilot")" = "$space_rollback_inode" ] || fail "space-path rollback changed old inode"
[ "$(hash_file "$space_install_dir/farpilot")" = "$space_rollback_hash" ] || fail "space-path rollback changed old bytes"
assert_no_managed_artifacts "$space_install_dir"

# Download verification failures preserve an existing installation exactly.
for preserve_case in preserve-checksum preserve-version; do
    new_case "$preserve_case"
    mkdir -p "$CASE/home/install-bin"
    cp "$tmp/old-version.sh" "$CASE/home/install-bin/farpilot"
    chmod +x "$CASE/home/install-bin/farpilot"
    preserved_inode=$(inode_of "$CASE/home/install-bin/farpilot")
    preserved_hash=$(hash_file "$CASE/home/install-bin/farpilot")
    if [ "$preserve_case" = preserve-checksum ]; then
        write_manifest "$CASE/downloads/latest.json" 9.8.7 v9.8.7 0000000000000000000000000000000000000000000000000000000000000000
    else
        cp "$tmp/bad-version.sh" "$CASE/downloads/farpilot-macos-aarch64"
        preserve_bad_sha=$(hash_file "$CASE/downloads/farpilot-macos-aarch64")
        write_manifest "$CASE/downloads/latest.json" 9.8.7 v9.8.7 "$preserve_bad_sha"
    fi
    run_install Darwin arm64 '' https://downloads.example/latest.json
    assert_failure
    [ "$(inode_of "$CASE/home/install-bin/farpilot")" = "$preserved_inode" ] || fail "$preserve_case changed inode"
    [ "$(hash_file "$CASE/home/install-bin/farpilot")" = "$preserved_hash" ] || fail "$preserve_case changed bytes"
    assert_no_managed_artifacts "$CASE/home/install-bin"
done

# A post-activation verification failure restores the exact old binary.
new_case activation-rollback
write_manifest "$CASE/downloads/latest.json" 9.8.7 v9.8.7 "$good_sha"
mkdir -p "$CASE/home/install-bin"
cp "$tmp/old-version.sh" "$CASE/home/install-bin/farpilot"
chmod +x "$CASE/home/install-bin/farpilot"
rollback_hash=$(hash_file "$CASE/home/install-bin/farpilot")
cat > "$CASE/bin/mv" <<'EOF'
#!/bin/sh
set -eu
source_path=$1
destination=$2
/bin/mv "$source_path" "$destination"
case "$source_path:$destination:${FARPILOT_TEST_CORRUPT_ACTIVATED:-0}" in
    *.staged.*:*/farpilot:1)
        printf '%s\n' '#!/bin/sh' 'exit 47' > "$destination"
        chmod +x "$destination"
        ;;
esac
EOF
chmod +x "$CASE/bin/mv"
export FARPILOT_TEST_CORRUPT_ACTIVATED=1
run_install Darwin arm64 '' https://downloads.example/latest.json
unset FARPILOT_TEST_CORRUPT_ACTIVATED
assert_failure
[ "$(hash_file "$CASE/home/install-bin/farpilot")" = "$rollback_hash" ] || fail "activation failure did not restore old binary"
assert_no_managed_artifacts "$CASE/home/install-bin"

# A staged-to-target move failure preserves the staged path for cleanup and restores the old inode.
new_case activation-move-failure
write_manifest "$CASE/downloads/latest.json" 9.8.7 v9.8.7 "$good_sha"
mkdir -p "$CASE/home/install-bin"
cp "$tmp/old-version.sh" "$CASE/home/install-bin/farpilot"
chmod +x "$CASE/home/install-bin/farpilot"
move_failure_inode=$(inode_of "$CASE/home/install-bin/farpilot")
move_failure_hash=$(hash_file "$CASE/home/install-bin/farpilot")
cat > "$CASE/bin/mv" <<'EOF'
#!/bin/sh
set -eu
source_path=$1
destination=$2
case "$source_path:$destination" in
    *.staged.*:*/farpilot) exit 73 ;;
esac
exec /bin/mv "$@"
EOF
chmod +x "$CASE/bin/mv"
run_install Darwin arm64 '' https://downloads.example/latest.json
assert_failure
assert_contains "$CASE/stderr" 'failed to activate FarPilot; previous version was restored'
[ "$(inode_of "$CASE/home/install-bin/farpilot")" = "$move_failure_inode" ] || fail "move failure changed old inode"
[ "$(hash_file "$CASE/home/install-bin/farpilot")" = "$move_failure_hash" ] || fail "move failure changed old bytes"
assert_no_managed_artifacts "$CASE/home/install-bin"

# Unsafe existing target types are refused and preserved.
for target_kind in symlink directory fifo; do
    new_case "unsafe-target-$target_kind"
    write_manifest "$CASE/downloads/latest.json" 9.8.7 v9.8.7 "$good_sha"
    mkdir -p "$CASE/home/install-bin"
    case "$target_kind" in
        symlink) ln -s "$tmp/old-version.sh" "$CASE/home/install-bin/farpilot" ;;
        directory) mkdir "$CASE/home/install-bin/farpilot" ;;
        fifo) mkfifo "$CASE/home/install-bin/farpilot" ;;
    esac
    run_install Darwin arm64 '' https://downloads.example/latest.json
    assert_failure
    case "$target_kind" in
        symlink) [ -L "$CASE/home/install-bin/farpilot" ] || fail "symlink target was replaced" ;;
        directory) [ -d "$CASE/home/install-bin/farpilot" ] || fail "directory target was replaced" ;;
        fifo) [ -p "$CASE/home/install-bin/farpilot" ] || fail "FIFO target was replaced" ;;
    esac
    assert_no_managed_artifacts "$CASE/home/install-bin"
done

# Dry run fetches metadata only and reports the complete plan without mutation.
new_case dry-run-cli
write_manifest "$CASE/downloads/latest.json" 9.8.7 v9.8.7 "$good_sha"
run_install Darwin arm64 '' https://downloads.example/latest.json --dry-run
assert_status 0
assert_contains "$CASE/stdout" 'role: cli'
assert_contains "$CASE/stdout" 'target: macos-aarch64'
assert_contains "$CASE/stdout" 'manifest: https://downloads.example/latest.json'
assert_contains "$CASE/stdout" 'version: 9.8.7'
assert_contains "$CASE/stdout" 'asset: https://downloads.example/farpilot-macos-aarch64'
assert_contains "$CASE/stdout" "destination: $CASE/home/install-bin/farpilot"
assert_absent "$CASE/home/install-bin"
assert_not_contains "$CASE/curl.log" 'farpilot-macos-aarch64'
assert_absent "$CASE/gateway.log"

# A held activation lock fails in bounded time and is never stolen.
new_case held-lock
write_manifest "$CASE/downloads/latest.json" 9.8.7 v9.8.7 "$good_sha"
mkdir -p "$CASE/home/install-bin/farpilot.install.lock"
cp "$tmp/old-version.sh" "$CASE/home/install-bin/farpilot"
chmod +x "$CASE/home/install-bin/farpilot"
locked_hash=$(hash_file "$CASE/home/install-bin/farpilot")
export FARPILOT_LOCK_RETRIES=1 FARPILOT_LOCK_DELAY=0
run_install Darwin arm64 '' https://downloads.example/latest.json
unset FARPILOT_LOCK_RETRIES FARPILOT_LOCK_DELAY
assert_failure
assert_contains "$CASE/stderr" 'another FarPilot installation is active'
[ -d "$CASE/home/install-bin/farpilot.install.lock" ] || fail "installer stole unknown lock"
[ "$(hash_file "$CASE/home/install-bin/farpilot")" = "$locked_hash" ] || fail "held lock changed target"
rm -rf "$CASE/home/install-bin/farpilot.install.lock"
assert_no_managed_artifacts "$CASE/home/install-bin"

# Gateway mode downloads a verified installer and forwards the selected manifest plus arguments.
new_case gateway-dispatch
write_manifest "$CASE/downloads/latest.json" 9.8.7 v9.8.7 "$good_sha"
export FARPILOT_TEST_GATEWAY_LOG="$CASE/gateway.log"
run_install Linux x86_64 '' https://downloads.example/latest.json gateway --domain gateway.example.com --email operator@example.com --version v9.8.7
unset FARPILOT_TEST_GATEWAY_LOG
assert_status 0
assert_contains "$CASE/curl.log" 'https://downloads.example/install-gateway.sh'
assert_contains "$CASE/gateway.log" '--manifest'
assert_contains "$CASE/gateway.log" '--domain'
assert_contains "$CASE/gateway.log" 'gateway.example.com'
assert_contains "$CASE/gateway.log" '--email'
assert_contains "$CASE/gateway.log" 'operator@example.com'
assert_contains "$CASE/gateway.log" '--version'
assert_contains "$CASE/gateway.log" 'v9.8.7'

# Global version/dry-run options before gateway are normalized and never download the installer in dry run.
new_case gateway-dry-run
write_manifest "$CASE/downloads/manifest.json" 9.8.7 v9.8.7 "$good_sha"
run_install Linux x86_64 '' DEFAULT --version 9.8.7 --dry-run gateway --domain gateway.example.com
assert_status 0
assert_contains "$CASE/stdout" 'role: gateway'
assert_contains "$CASE/stdout" 'version: 9.8.7'
assert_contains "$CASE/stdout" 'installer: https://downloads.example/install-gateway.sh'
assert_not_contains "$CASE/curl.log" 'install-gateway.sh'
assert_absent "$CASE/gateway.log"

# Gateway checksum mismatch never executes the downloaded script.
new_case gateway-checksum-mismatch
write_manifest "$CASE/downloads/latest.json" 9.8.7 v9.8.7 "$good_sha"
sed "s/$gateway_sha/0000000000000000000000000000000000000000000000000000000000000000/" "$CASE/downloads/latest.json" > "$CASE/downloads/manifest.bad"
mv "$CASE/downloads/manifest.bad" "$CASE/downloads/latest.json"
export FARPILOT_TEST_GATEWAY_LOG="$CASE/gateway.log"
run_install Linux x86_64 '' https://downloads.example/latest.json gateway --domain gateway.example.com
unset FARPILOT_TEST_GATEWAY_LOG
assert_failure
assert_contains "$CASE/stderr" 'Gateway installer checksum did not match'
assert_absent "$CASE/gateway.log"

# Gateway parser ignores shadows and rejects duplicate gateway records/fields.
new_case gateway-shadow
cat > "$CASE/downloads/latest.json" <<EOF
{
  "shadow": {
    "gateway": {
      "sha256": "0000000000000000000000000000000000000000000000000000000000000000",
      "url": "https://downloads.example/shadow-gateway.sh"
    }
  },
  "assets": {},
  "installers": {
    "gateway": {
      "sha256": "$gateway_sha",
      "url": "https://downloads.example/install-gateway.sh"
    }
  },
  "schema_version": 1,
  "tag": "v9.8.7",
  "version": "9.8.7"
}
EOF
export FARPILOT_TEST_GATEWAY_LOG="$CASE/gateway.log"
run_install Linux x86_64 '' https://downloads.example/latest.json gateway --domain gateway.example.com
unset FARPILOT_TEST_GATEWAY_LOG
assert_status 0
assert_not_contains "$CASE/curl.log" 'shadow-gateway.sh'

for gateway_duplicate in installers gateway url sha256; do
    new_case "gateway-duplicate-$gateway_duplicate"
    case "$gateway_duplicate" in
        installers)
            cat > "$CASE/downloads/latest.json" <<EOF
{
  "assets": {},
  "installers": {
    "gateway": {
      "sha256": "$gateway_sha",
      "url": "https://downloads.example/install-gateway.sh"
    }
  },
  "installers": {
    "gateway": {
      "sha256": "$gateway_sha",
      "url": "https://downloads.example/install-gateway.sh"
    }
  },
  "schema_version": 1,
  "tag": "v9.8.7",
  "version": "9.8.7"
}
EOF
            expected_gateway_error='duplicate top-level key: installers'
            ;;
        gateway)
            cat > "$CASE/downloads/latest.json" <<EOF
{
  "assets": {},
  "installers": {
    "gateway": {
      "sha256": "$gateway_sha",
      "url": "https://downloads.example/install-gateway.sh"
    },
    "gateway": {
      "sha256": "$gateway_sha",
      "url": "https://downloads.example/install-gateway.sh"
    }
  },
  "schema_version": 1,
  "tag": "v9.8.7",
  "version": "9.8.7"
}
EOF
            expected_gateway_error='duplicate installer key: gateway'
            ;;
        url|sha256)
            duplicate_gateway_line='      "url": "https://downloads.example/install-gateway.sh"'
            [ "$gateway_duplicate" = sha256 ] && duplicate_gateway_line="      \"sha256\": \"$gateway_sha\""
            cat > "$CASE/downloads/latest.json" <<EOF
{
  "assets": {},
  "installers": {
    "gateway": {
      "sha256": "$gateway_sha",
      "url": "https://downloads.example/install-gateway.sh",
$duplicate_gateway_line
    }
  },
  "schema_version": 1,
  "tag": "v9.8.7",
  "version": "9.8.7"
}
EOF
            expected_gateway_error="duplicate gateway installer field: $gateway_duplicate"
            ;;
    esac
    run_install Linux x86_64 '' https://downloads.example/latest.json gateway --domain gateway.example.com
    assert_failure
    assert_contains "$CASE/stderr" "$expected_gateway_error"
done

new_case gateway-malformed-nesting
cat > "$CASE/downloads/latest.json" <<EOF
{
  "assets": {},
  "installers": {
  "gateway": {
      "sha256": "$gateway_sha",
      "url": "https://downloads.example/install-gateway.sh"
    }
  },
  "schema_version": 1,
  "tag": "v9.8.7",
  "version": "9.8.7"
}
EOF
run_install Linux x86_64 '' https://downloads.example/latest.json gateway --domain gateway.example.com
assert_failure
assert_contains "$CASE/stderr" 'malformed object nesting'

# A signal after backup creation restores the old target and cleans owned artifacts.
new_case signal-rollback
write_manifest "$CASE/downloads/latest.json" 9.8.7 v9.8.7 "$good_sha"
mkdir -p "$CASE/home/install-bin"
cp "$tmp/old-version.sh" "$CASE/home/install-bin/farpilot"
chmod +x "$CASE/home/install-bin/farpilot"
signal_hash=$(hash_file "$CASE/home/install-bin/farpilot")
cat > "$CASE/bin/mv" <<'EOF'
#!/bin/sh
set -eu
source_path=$1
destination=$2
/bin/mv "$source_path" "$destination"
case "$destination:${FARPILOT_TEST_SIGNAL_READY:-}" in
    *.backup.*:*)
        : > "$FARPILOT_TEST_SIGNAL_READY"
        sleep 30
        ;;
esac
EOF
chmod +x "$CASE/bin/mv"
signal_ready=$CASE/signal.ready
set +e
env \
    FARPILOT_TEST_DOWNLOADS="$CASE/downloads" \
    FARPILOT_TEST_CURL_LOG="$CASE/curl.log" \
    FARPILOT_TEST_SIGNAL_READY="$signal_ready" \
    FARPILOT_UNAME_S=Darwin \
    FARPILOT_UNAME_M=arm64 \
    FARPILOT_UNAME_O= \
    FARPILOT_MANIFEST_URL=https://downloads.example/latest.json \
    FARPILOT_INSTALL_DIR="$CASE/home/install-bin" \
    HOME="$CASE/home" \
    PATH="$CASE/bin:/usr/bin:/bin" \
    sh "$root/install.sh" >"$CASE/stdout" 2>"$CASE/stderr" &
signal_pid=$!
signal_wait=0
while [ ! -f "$signal_ready" ] && [ "$signal_wait" -lt 100 ]; do
    sleep 0.05
    signal_wait=$((signal_wait + 1))
done
if [ ! -f "$signal_ready" ]; then
    kill "$signal_pid" 2>/dev/null || true
    wait "$signal_pid" 2>/dev/null || true
    set -e
    fail "signal test never reached backup point"
fi
kill -TERM "$signal_pid"
wait "$signal_pid"
signal_status=$?
set -e
[ "$signal_status" -ne 0 ] || fail "signalled installer unexpectedly succeeded"
[ "$(hash_file "$CASE/home/install-bin/farpilot")" = "$signal_hash" ] || fail "signal did not restore old binary"
assert_no_managed_artifacts "$CASE/home/install-bin"

printf '%s\n' 'POSIX installer tests passed'
