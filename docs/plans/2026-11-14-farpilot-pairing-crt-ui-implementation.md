# FarPilot CRT Pairing Page Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the raw server-rendered QR pairing form with a secure, mobile-first Retro CRT experience that includes countdown, accessible form states, in-place success, and generic themed browser errors without changing the Claim API.

**Architecture:** A focused Rust `pairing_page` module embeds one self-contained HTML/CSS/JavaScript template at compile time, renders only an allowlisted context with strict encoding, and returns a per-response CSP nonce plus browser security headers. `pairing_http` keeps database/rate-limit/API responsibilities and delegates browser presentation to the renderer.

**Tech Stack:** Rust stable, Axum, `rand`, `base64`, server-rendered HTML, vanilla CSS/JavaScript, existing Cargo integration tests.

**Approved specification:** `docs/specs/2026-11-14-farpilot-pairing-crt-ui-design.md`

**Repository policy:** Local commits on `feature/pairing-crt-ui` are authorized by the approved session goal. Do not push, merge, or deploy without a separate explicit instruction.

---

## File map

```text
crates/farpilot-gateway/
├── src/
│   ├── lib.rs                         # Export the focused pairing_page module
│   ├── pairing_http.rs                # Keep routes/API; delegate browser HTML responses
│   ├── pairing_page.rs                # Context, state enum, nonce, rendering, browser headers
│   └── pairing_page.html              # Self-contained CRT HTML/CSS/JS template
└── tests/
    └── pairing_http.rs                # Route/status/API compatibility and rendered security tests
```

`pairing_page.rs` must stay independent of SQLite and request extraction. `pairing_http.rs` remains the only module that knows stores, rate limits, and HTTP route semantics.

---

### Task 1: Secure pairing-page renderer boundary

**Files:**
- Create: `crates/farpilot-gateway/src/pairing_page.rs`
- Create: `crates/farpilot-gateway/src/pairing_page.html`
- Modify: `crates/farpilot-gateway/src/lib.rs`
- Test: unit tests inside `crates/farpilot-gateway/src/pairing_page.rs`

- [ ] **Step 1: Write failing renderer tests**

Add tests for a wished-for renderer API:

```rust
use super::{PairingPageContext, PairingPageState, render_pairing_page};

fn context() -> PairingPageContext {
    PairingPageContext {
        host_display_name: "Company DevBox".into(),
        gateway_host: "gateway.example.com".into(),
        gateway_port: 22,
        ssh_host_fingerprint: "SHA256:gateway-test".into(),
        expires_at_ms: 1_800_000_000_000,
        claim_path: "/v1/pair/test-secret/claim".into(),
    }
}

#[test]
fn ready_page_escapes_text_and_attributes_and_resolves_placeholders() {
    let mut value = context();
    value.host_display_name = "<script>alert(1)</script> & \"host\"".into();
    value.claim_path = "/v1/pair/a'b\"c/claim".into();
    let page = render_pairing_page(PairingPageState::Ready(value)).unwrap();
    assert!(page.body.contains("&lt;script&gt;alert(1)&lt;/script&gt;"));
    assert!(!page.body.contains("<script>alert(1)</script>"));
    assert!(page.body.contains("a&#39;b&quot;c"));
}

#[test]
fn dynamic_text_that_looks_like_a_token_is_not_reinterpreted() {
    let mut value = context();
    value.host_display_name = "{{FARPILOT_GATEWAY_TEXT}}".into();
    let page = render_pairing_page(PairingPageState::Ready(value)).unwrap();
    assert!(page.body.contains("{{FARPILOT_GATEWAY_TEXT}}"));
    assert!(page.body.contains("gateway.example.com"));
}

#[test]
fn each_page_has_one_style_and_script_with_the_same_nonce() {
    let first = render_pairing_page(PairingPageState::Ready(context())).unwrap();
    let second = render_pairing_page(PairingPageState::Ready(context())).unwrap();
    assert_ne!(first.nonce, second.nonce);
    assert_eq!(first.body.matches(&format!("nonce=\"{}\"", first.nonce)).count(), 2);
    assert!(first.csp.contains(&format!("style-src 'nonce-{}'", first.nonce)));
    assert!(first.csp.contains(&format!("script-src 'nonce-{}'", first.nonce)));
}

#[test]
fn invalid_page_has_no_host_metadata() {
    let page = render_pairing_page(PairingPageState::Invalid).unwrap();
    assert!(page.body.contains("SESSION INVALID"));
    assert!(!page.body.contains("Company DevBox"));
    assert!(!page.body.contains("gateway.example.com"));
}
```

Also test that a context containing a reserved marker such as `{{FARPILOT_HOST}}` is encoded as user text rather than interpreted as a second template pass.

- [ ] **Step 2: Run the tests and verify RED**

Run:

```bash
cargo test -p farpilot-gateway pairing_page --lib
```

Expected: compile failure because `pairing_page` and its API do not exist.

- [ ] **Step 3: Define renderer types**

Create `pairing_page.rs`:

```rust
use base64::Engine;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use rand::RngCore;
use rand::rngs::OsRng;
use thiserror::Error;

const TEMPLATE: &str = include_str!("pairing_page.html");
const RESERVED_PREFIX: &str = "{{FARPILOT_";

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PairingPageContext {
    pub host_display_name: String,
    pub gateway_host: String,
    pub gateway_port: u16,
    pub ssh_host_fingerprint: String,
    pub expires_at_ms: u64,
    pub claim_path: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum PairingPageState {
    Ready(PairingPageContext),
    Invalid,
    RateLimited,
    InternalError,
}

#[derive(Debug, Eq, PartialEq)]
pub struct RenderedPairingPage {
    pub body: String,
    pub nonce: String,
    pub csp: String,
}

#[derive(Debug, Error, Eq, PartialEq)]
pub enum PairingPageRenderError {
    #[error("pairing page template token inventory is invalid")]
    InvalidTemplateTokens,
}
```

Use a 16-byte `OsRng` nonce encoded with URL-safe base64 without padding.

- [ ] **Step 4: Implement single-pass token rendering**

Use fixed unique tokens:

```text
{{FARPILOT_NONCE}}
{{FARPILOT_PAGE_STATE}}
{{FARPILOT_HOST_TEXT}}
{{FARPILOT_GATEWAY_TEXT}}
{{FARPILOT_PORT_TEXT}}
{{FARPILOT_FINGERPRINT_TEXT}}
{{FARPILOT_EXPIRES_ATTR}}
{{FARPILOT_CLAIM_PATH_ATTR}}
```

Encode every dynamic value before a single replacement pass. Text and quoted attribute values both encode `&`, `<`, `>`, `"`, and `'`. Replacement values are never rescanned for tokens.

Build CSP exactly from the generated nonce:

```rust
let csp = format!(
    "default-src 'none'; style-src 'nonce-{nonce}'; script-src 'nonce-{nonce}'; \
     connect-src 'self'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'"
);
```

Before replacement, validate `TEMPLATE` with a focused `validate_template_tokens` helper: each allowlisted token must appear exactly its required count, and removing all known tokens from a copy must leave no `RESERVED_PREFIX`. Then perform one-pass replacements without rescanning dynamic values. Add unit tests that malformed synthetic templates with a missing, duplicate, or unknown token return `InvalidTemplateTokens`.

- [ ] **Step 5: Create a minimal valid template skeleton**

Create `pairing_page.html` with exactly one nonce-protected style and script, no external resource:

```html
<!doctype html>
<html lang="zh-CN" data-page-state="{{FARPILOT_PAGE_STATE}}">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>FarPilot // Pair</title>
  <style nonce="{{FARPILOT_NONCE}}">body { background: #020504; color: #78ff87; }</style>
</head>
<body>
  <main id="pairing-shell"
        data-claim-path="{{FARPILOT_CLAIM_PATH_ATTR}}"
        data-expires-at-ms="{{FARPILOT_EXPIRES_ATTR}}">
    <h1>{{FARPILOT_HOST_TEXT}}</h1>
    <p>{{FARPILOT_GATEWAY_TEXT}}:{{FARPILOT_PORT_TEXT}}</p>
    <code>{{FARPILOT_FINGERPRINT_TEXT}}</code>
  </main>
  <script nonce="{{FARPILOT_NONCE}}">'use strict';</script>
</body>
</html>
```

Error states receive empty metadata values and render only their generic state content in later tasks.

- [ ] **Step 6: Export the module and verify GREEN**

Add to `src/lib.rs`:

```rust
pub mod pairing_page;
```

Run:

```bash
cargo test -p farpilot-gateway pairing_page --lib
cargo fmt --all -- --check
cargo clippy -p farpilot-gateway --all-targets --all-features -- -D warnings
```

Expected: renderer tests pass with no warnings.

- [ ] **Step 7: Commit checkpoint**

```bash
git add crates/farpilot-gateway/src/lib.rs \
  crates/farpilot-gateway/src/pairing_page.rs \
  crates/farpilot-gateway/src/pairing_page.html
git commit -m "feat: add secure pairing page renderer"
```

---

### Task 2: Retro CRT form and accessible responsive styling

**Files:**
- Modify: `crates/farpilot-gateway/src/pairing_page.html`
- Modify: `crates/farpilot-gateway/src/pairing_page.rs`
- Test: unit tests inside `crates/farpilot-gateway/src/pairing_page.rs`

- [ ] **Step 1: Write failing static UI contract tests**

Add tests that inspect `TEMPLATE` or rendered ready output:

```rust
#[test]
fn template_contains_approved_crt_and_accessibility_contract() {
    for required in [
        "FARPILOT // SECURE RELAY",
        "授权远程终端",
        "AUTHORIZE REMOTE TERMINAL",
        "AUTH WINDOW",
        "DEVICE_NAME",
        "SSH_ED25519_PUBLIC_KEY",
        "aria-live=\"polite\"",
        "prefers-reduced-motion: reduce",
        "min-height: 44px",
        "@media (max-width: 360px)",
    ] {
        assert!(TEMPLATE.contains(required), "missing {required}");
    }
}

#[test]
fn template_has_no_external_resource_or_dangerous_dom_sink() {
    for forbidden in [
        "<script src=",
        "<link rel=\"stylesheet\"",
        "http://",
        "https://",
        "innerHTML",
        "insertAdjacentHTML",
        "document.write",
        "eval(",
        "new Function",
    ] {
        assert!(!TEMPLATE.contains(forbidden), "forbidden {forbidden}");
    }
}
```

Add a rendered-page size ceiling test, initially `96 * 1024` bytes. Lower it only after measuring the final page; never increase it to hide accidental embedded assets.

- [ ] **Step 2: Run tests and verify RED**

Run:

```bash
cargo test -p farpilot-gateway pairing_page --lib
```

Expected: static contract tests fail because the minimal template lacks the approved UI.

- [ ] **Step 3: Build the semantic form DOM**

Implement one CRT shell with:

```html
<div class="crt" data-ui-state="ready">
  <div class="scanlines" aria-hidden="true"></div>
  <header class="telemetry">
    <span>FARPILOT // SECURE RELAY</span>
    <span class="online">● ONLINE</span>
  </header>
  <section id="ready-state">
    <h1>授权远程终端<span class="cursor" aria-hidden="true">█</span></h1>
    <p class="eyebrow">AUTHORIZE REMOTE TERMINAL</p>
    <dl class="connection-data">
      <dt>TARGET</dt><dd id="host-value">{{FARPILOT_HOST_TEXT}}</dd>
      <dt>GATEWAY</dt><dd><span id="gateway-value">{{FARPILOT_GATEWAY_TEXT}}</span>:<span id="port-value">{{FARPILOT_PORT_TEXT}}</span></dd>
      <dt>KEY</dt><dd id="fingerprint-value">{{FARPILOT_FINGERPRINT_TEXT}}</dd>
    </dl>
    <p class="security-note">请与管理员提供的 SSH 指纹逐字比对。</p>
    <form id="pair-form" novalidate>
      <label for="device-name">DEVICE_NAME</label>
      <input id="device-name" name="device-name" maxlength="64" required autocomplete="off" aria-describedby="device-error">
      <p id="device-error" class="field-error" hidden></p>
      <label for="ssh-key">SSH_ED25519_PUBLIC_KEY</label>
      <textarea id="ssh-key" name="ssh-key" required spellcheck="false" autocapitalize="off" autocomplete="off" aria-describedby="key-help key-error"></textarea>
      <p id="key-help" class="field-help">仅粘贴公钥。私钥始终保留在你的设备上。</p>
      <p id="key-error" class="field-error" hidden></p>
      <button id="submit-button" type="submit">[ AUTHORIZE DEVICE ]</button>
    </form>
    <div class="auth-window"><span>AUTH WINDOW</span><time id="countdown">--:--</time></div>
  </section>
  <section id="terminal-state" hidden></section>
  <p id="page-status" class="sr-only" aria-live="polite"></p>
</div>
```

Use real labels, `dl`, status region, and hidden state sections. Do not create clickable `<div>` controls.

- [ ] **Step 4: Implement the approved CRT CSS**

Add CSS variables for the approved palette, system monospace stack, radial CRT background, bezel, noninteractive scanlines, focus rings, error/warning colors, responsive width, long fingerprint wrapping, and 44 px controls.

Required reduced-motion rule:

```css
@media (prefers-reduced-motion: reduce) {
  *, *::before, *::after {
    animation-duration: 0.01ms !important;
    animation-iteration-count: 1 !important;
    scroll-behavior: auto !important;
  }
}
```

No flicker animation is implemented. The only default animation is a slow block-cursor opacity change.

- [ ] **Step 5: Run renderer/static tests and inspect page size**

Run:

```bash
cargo test -p farpilot-gateway pairing_page --lib
cargo fmt --all -- --check
cargo clippy -p farpilot-gateway --all-targets --all-features -- -D warnings
```

Expected: tests pass and page remains under the documented ceiling.

- [ ] **Step 6: Commit checkpoint**

```bash
git add crates/farpilot-gateway/src/pairing_page.html \
  crates/farpilot-gateway/src/pairing_page.rs
git commit -m "feat: style pairing form as retro CRT"
```

---

### Task 3: Countdown and client state machine

**Files:**
- Modify: `crates/farpilot-gateway/src/pairing_page.html`
- Modify: `crates/farpilot-gateway/src/pairing_page.rs`
- Test: unit/static tests in `pairing_page.rs`

- [ ] **Step 1: Write failing JavaScript contract tests**

Assert the template defines and uses these focused functions:

```text
setUiState
updateCountdown
expireSession
setFieldError
clearErrors
mapApiError
renderSuccess
renderTerminalError
submitPairing
```

Require:

```text
Date.now()
setInterval(updateCountdown, 1000)
response.status === 201
response.json()
textContent
AbortController
```

Reject dangerous DOM sinks from Task 2. Require API mapping literals for every specified error code and terminal status.

- [ ] **Step 2: Run tests and verify RED**

Run:

```bash
cargo test -p farpilot-gateway pairing_page --lib
```

Expected: JavaScript contract tests fail.

- [ ] **Step 3: Implement countdown behavior**

Inside the nonce-protected script:

```javascript
const shell = document.getElementById('pairing-shell');
const expiresAtMs = Number(shell.dataset.expiresAtMs);
let countdownTimer = null;

function updateCountdown() {
  const remainingMs = Math.max(0, expiresAtMs - Date.now());
  const totalSeconds = Math.ceil(remainingMs / 1000);
  const minutes = String(Math.floor(totalSeconds / 60)).padStart(2, '0');
  const seconds = String(totalSeconds % 60).padStart(2, '0');
  document.getElementById('countdown').textContent = `${minutes}:${seconds}`;
  if (remainingMs <= 0) expireSession();
}
```

`expireSession` clears the interval, disables controls, and renders `SESSION EXPIRED` with fixed Chinese guidance. It sends no request.

- [ ] **Step 4: Implement validation and submission**

Client validation trims the device name, checks 1–64 non-control characters, and requires the key to begin with exactly `ssh-ed25519 ` plus nonempty encoded content. It does not attempt to validate the key blob.

Submission:

```javascript
const response = await fetch(shell.dataset.claimPath, {
  method: 'POST',
  headers: { 'content-type': 'application/json' },
  body: JSON.stringify({ device_name: deviceName, ssh_public_key: sshKey }),
  signal: controller.signal,
  credentials: 'same-origin',
  redirect: 'error',
  referrerPolicy: 'no-referrer'
});
```

Treat only HTTP `201 Created` plus a valid allowlisted response shape as success. Map every other status/code to a fixed state; never insert raw response text.

- [ ] **Step 5: Implement in-place success state**

`renderSuccess` clears the timer and builds the approved terminal state using DOM creation plus `textContent`. It shows the four completed log lines, `PAIRING COMPLETE`, Host context, `ssh_host`, `ssh_port`, `ssh_username`, and `ssh_host_fingerprint`, followed by Moshi instructions and `SESSION SEALED // TOKEN CONSUMED`.

Do not use string-to-HTML insertion. Do not render `device_id` or `host_id` unless needed for a tested user-facing purpose; the approved design does not display them.

- [ ] **Step 6: Run tests and verify GREEN**

Run:

```bash
cargo test -p farpilot-gateway pairing_page --lib
cargo fmt --all -- --check
cargo clippy -p farpilot-gateway --all-targets --all-features -- -D warnings
```

Expected: static state-machine contracts pass.

- [ ] **Step 7: Commit checkpoint**

```bash
git add crates/farpilot-gateway/src/pairing_page.html \
  crates/farpilot-gateway/src/pairing_page.rs
git commit -m "feat: add pairing page state machine"
```

---

### Task 4: Integrate browser pages without changing Claim API

**Files:**
- Modify: `crates/farpilot-gateway/src/pairing_http.rs`
- Modify: `crates/farpilot-gateway/tests/pairing_http.rs`
- Modify: `crates/farpilot-gateway/src/pairing_page.rs`

- [ ] **Step 1: Write failing route and header tests**

Extend integration tests to require:

```rust
assert_eq!(page.status(), StatusCode::OK);
assert_eq!(page.headers()["cache-control"], "no-store");
assert_eq!(page.headers()["referrer-policy"], "no-referrer");
assert_eq!(page.headers()["x-content-type-options"], "nosniff");
assert_eq!(page.headers()["x-frame-options"], "DENY");
assert!(page.headers()["content-security-policy"]
    .to_str().unwrap().contains("default-src 'none'"));
```

For unknown, expired, and consumed tokens, assert status `404`, `text/html`, `SESSION INVALID`, no Host/Gateway metadata, and the same public copy/DOM state after normalizing the nonce.

For rate limiting, assert the sixth GET returns themed `429` and `TOO MANY ATTEMPTS`.

Preserve Claim tests asserting JSON content type/status/error codes, key normalization, grant creation, and `authorized_keys` update.

- [ ] **Step 2: Run integration tests and verify RED**

Run:

```bash
cargo test -p farpilot-gateway --test pairing_http
```

Expected: tests fail because routes still return the old raw page/JSON GET errors and lack application headers.

- [ ] **Step 3: Add a browser response helper**

In `pairing_http.rs`, create a helper that accepts HTTP status and `PairingPageState`, renders the page, and returns HTML with all required headers. If rendering unexpectedly fails, return a fixed minimal plain-text `500` with `no-store` and no token/Host data; do not recursively call the renderer.

Use `header::CACHE_CONTROL` and `header::CONTENT_TYPE`; construct `content-security-policy`, `referrer-policy`, `x-content-type-options`, and `x-frame-options` with `HeaderName::from_static` so the code does not depend on unavailable nonstandard constants.

- [ ] **Step 4: Delegate valid GET rendering**

Replace the inline `format!` HTML in `pairing_page` with:

```rust
browser_page(
    StatusCode::OK,
    PairingPageState::Ready(PairingPageContext {
        host_display_name: preview.host_display_name,
        gateway_host: state.config.public_ssh_host.clone(),
        gateway_port: state.config.public_ssh_port,
        ssh_host_fingerprint: state.config.ssh_host_fingerprint.clone(),
        expires_at_ms: preview.expires_at_ms,
        claim_path: format!("/v1/pair/{secret}/claim"),
    }),
)
```

The raw secret is used only to build the relative Claim path and is encoded by the renderer before entering an attribute.

- [ ] **Step 5: Theme browser GET errors only**

For `pairing_page` GET:

- rate-limited → `browser_page(429, RateLimited)`;
- unknown/expired/consumed → record failure then `browser_page(404, Invalid)`;
- store error → `browser_page(500, InternalError)`.

Do not change `enroll_host`, `claim_device`, JSON rejection, or JSON `error()` behavior.

- [ ] **Step 6: Verify API compatibility and generic behavior**

Run:

```bash
cargo test -p farpilot-gateway --test pairing_http
cargo test -p farpilot-gateway
cargo fmt --all -- --check
cargo clippy --workspace --all-targets --all-features -- -D warnings
```

Expected: browser tests and existing Claim tests pass.

- [ ] **Step 7: Commit checkpoint**

```bash
git add crates/farpilot-gateway/src/pairing_http.rs \
  crates/farpilot-gateway/src/pairing_page.rs \
  crates/farpilot-gateway/tests/pairing_http.rs
git commit -m "feat: serve secure CRT pairing pages"
```

---

### Task 5: Visual preview, mobile acceptance, and full regression

Manual visual acceptance uses only sanitized synthetic metadata and never a live pairing token.

**Files:**
- Modify: `docs/stage0-runbook.md`
- Modify: `docs/stage0-acceptance.md`
- Modify: tests only if acceptance reveals a real defect

- [ ] **Step 1: Add a sanitized visual-acceptance checklist**

Document the approved checks without real Host names, fingerprints, keys, or tokens:

```text
320 px no horizontal scroll
long synthetic Host wraps
full synthetic fingerprint wraps without truncation
labels/focus/keyboard order
44 px touch controls
countdown/expiry
success/error states
reduced motion
no external requests
```

Do not mark checks Pass until observed.

- [ ] **Step 2: Run the complete automated verification**

Run:

```bash
cargo fmt --all -- --check
cargo clippy --workspace --all-targets --all-features -- -D warnings
cargo test --workspace
cargo test --doc --workspace
python3 -m unittest discover -s tests/release -v
bash tests/workspace_layout.sh
bash tests/install/install_sh.sh
bash tests/install/gateway_installer.sh
bash tests/security/deployment_assets.sh
bash tests/security/sshd_restrictions.sh
bash tests/e2e/gateway-host.sh
bash tests/release/workflow_assets.sh
git diff --check
```

Expected: zero failures and warnings.

- [ ] **Step 3: Produce a local sanitized preview**

Use a temporary local fixture or test-only route to render a page with:

```text
Host: Example DevBox
Gateway: gateway.example.com:22
Fingerprint: SHA256:synthetic-public-value
Expiry: five minutes from preview start
Claim path: /v1/pair/synthetic-token/claim
```

Never use a real token, fingerprint, public key, hostname, or production Gateway. Do not commit the rendered page.

- [ ] **Step 4: Inspect desktop/mobile and all states**

Using the approved browser testing/visual tool, inspect 320 px, 390 px, and desktop widths. Capture screenshots outside the repository or under ignored temporary state. Verify Ready, Submitting, Success, Expired, Invalid, RateLimited, InternalError, field error, and reduced-motion states.

If a defect is found, add a failing automated contract/integration test before changing implementation.

- [ ] **Step 5: Record only observed sanitized evidence**

Update `docs/stage0-acceptance.md` with the date, synthetic fixture, browser/viewport, and Pass/Fail for each check. Keep real-device public pairing acceptance Pending until deployed.

- [ ] **Step 6: Final independent review**

Request an independent security/UI code review of the full diff against the approved spec. Fix every confirmed Critical or Important issue with a failing regression and rerun Step 2.

- [ ] **Step 7: Commit checkpoint**

```bash
git add docs/stage0-runbook.md docs/stage0-acceptance.md
git commit -m "docs: record CRT pairing page acceptance"
```

- [ ] **Step 8: Stop before deployment**

Show branch status and commits. Do not push, merge, deploy Gateway, or create a live pairing token without explicit user instruction.
