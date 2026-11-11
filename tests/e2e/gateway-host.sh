#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
export RUST_BACKTRACE=1
cargo test --manifest-path "$root/Cargo.toml" -p farpilot-core --test protocol
cargo test --manifest-path "$root/Cargo.toml" -p farpilot-core --test identity_pairing
cargo test --manifest-path "$root/Cargo.toml" -p farpilot-gateway --test store
cargo test --manifest-path "$root/Cargo.toml" -p farpilot-gateway --test pairing_http
cargo test --manifest-path "$root/Cargo.toml" -p farpilot-gateway --test broker
cargo test --manifest-path "$root/Cargo.toml" -p farpilot-gateway --test ssh_attach
cargo test --manifest-path "$root/Cargo.toml" -p farpilot-host --test connection
cargo test --manifest-path "$root/Cargo.toml" -p farpilot-host --test host_flow
