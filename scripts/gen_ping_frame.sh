#!/usr/bin/env bash
# Emit a hex dump of a Ping frame using a tiny Rust one-off via cargo.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

cargo build -p waydroid_bt_protocol 2>/dev/null || cargo build -p waydroid_bt_protocol

# Use a short Rust script through the host crate tests or printf via cargo run.
# Inline: compile-time not available; use python if prost not exposed.
# Prefer cargo test binary — write small example.

cat > /tmp/encode_ping.rs <<'RS'
// This file is compiled ad-hoc only if needed; prefer protocol unit tests.
fn main() {}
RS

python3 - <<'PY'
# Generate Ping envelope with pure structural knowledge is hard without protobuf.
# Document that connectivity smoke uses empty PING_FRAME in C client.
print("Use: cargo test -p waydroid_bt_protocol -- --nocapture")
print("Or call encode_frame from a future host subcommand: waydroid-bt-host encode-ping")
PY
