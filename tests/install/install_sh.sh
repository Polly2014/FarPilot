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
    grep -Fq -- "$value" "$file" || fail "expected '$value' in $file"
}

assert_absent() {
    [ ! -e "$1" ] && [ ! -L "$1" ] || fail "expected path to be absent: $1"
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
      "sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
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
    : > "$CASE/curl.log"
}

run_install() {
    os=$1
    arch=$2
    uname_o=$3
    manifest_url=$4
    shift 4
    set +e
    if [ "$manifest_url" = DEFAULT ]; then
        env \
            FARPILOT_TEST_DOWNLOADS="$CASE/downloads" \
            FARPILOT_TEST_CURL_LOG="$CASE/curl.log" \
            FARPILOT_UNAME_S="$os" \
            FARPILOT_UNAME_M="$arch" \
            FARPILOT_UNAME_O="$uname_o" \
            FARPILOT_INSTALL_DIR="$CASE/home/install-bin" \
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
            FARPILOT_INSTALL_DIR="$CASE/home/install-bin" \
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

# Task 2 parses the Gateway role but does not dispatch until Task 3.
new_case gateway-role
run_install Linux x86_64 '' DEFAULT gateway --domain gateway.example.com
assert_failure
assert_contains "$CASE/stderr" 'gateway installation is not available yet'

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

printf '%s\n' 'POSIX installer tests passed'
