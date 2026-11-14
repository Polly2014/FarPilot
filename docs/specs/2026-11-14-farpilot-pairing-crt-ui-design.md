# FarPilot CRT Pairing Page Design

**Status:** Approved design; implementation not started

**Date:** 2026-11-14

## 1. Product decision

FarPilot's QR pairing page will be redesigned as a mobile-first retro CRT terminal while preserving the existing pairing protocol, authorization model, and no-framework deployment boundary.

The selected visual direction is **Retro CRT**:

- black and deep-green phosphor palette;
- monospace typography;
- restrained scanlines and glow;
- Chinese explanatory copy with English terminal labels and statuses;
- one mobile card that transforms in place from form to success state;
- visible authentication countdown;
- no external fonts, images, scripts, stylesheets, frameworks, or CDN requests.

The page remains a security operation first and a visual artifact second. The CRT treatment must never obscure the SSH host fingerprint, form labels, validation errors, countdown, or next-step instructions.

## 2. Goals

1. Make the QR pairing page visually distinctive and recognizably developer-oriented.
2. Preserve a clear, trustworthy path for entering a device name and Ed25519 public key.
3. Display Gateway host, port, and full SSH fingerprint prominently before authorization.
4. Show the real token expiry as a live `AUTH WINDOW` countdown.
5. Prevent submission after expiry and replace the form with a clear expired state.
6. Replace raw JSON success output with an in-place `PAIRING COMPLETE` terminal state.
7. Provide actionable Chinese instructions for configuring the resulting Moshi SSH profile.
8. Give invalid, expired, consumed, rate-limited, and internal-error browser requests themed but generic error pages.
9. Keep all existing server-side validation, single-use token behavior, rate limiting, key normalization, grant creation, and `authorized_keys` synchronization unchanged.
10. Enforce browser security headers even when Gateway is accessed without Nginx.

## 3. Non-goals

The redesign will not add:

- a frontend framework or package manager;
- a client-side router;
- external assets or analytics;
- automatic Moshi profile import;
- private-key generation or storage;
- clipboard access for the SSH fingerprint;
- a custom SSH key parser in JavaScript;
- a new pairing API or response schema;
- account login, organization selection, or multi-user administration;
- an unreliable `window.close()` control;
- intense flicker, typing animations, sound, or high-motion cyberpunk effects.

## 4. Visual system

### 4.1 Palette

The core palette is:

```text
Page background         #020504
CRT shell               #030704 → #102515 radial gradient
Outer bezel             #171d18
Primary phosphor        #78ff87
Bright heading          #d4ffd8
Muted body              #9bcaa2
Muted telemetry         #63866a
Panel background        rgba(4, 13, 6, 0.78)
Panel border            #2e6939
Input background        #061008
Input border             #397747
Error                    #ff8f78
Warning                  #ffd56a
```

Pure white is limited to the block cursor and tiny emphasis. Long-form body text uses muted green rather than maximum-brightness phosphor.

### 4.2 Typography

Use the system monospace stack only:

```css
ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas,
"Liberation Mono", "Courier New", monospace
```

No font request is made. Chinese text falls back to the platform's monospace-compatible system rendering.

### 4.3 CRT treatment

The CRT shell uses:

- a dark radial gradient;
- a thick, rounded bezel;
- restrained inset shadow;
- a pointer-transparent repeating scanline overlay;
- subtle text glow on short labels and headings only;
- a block cursor animation on active terminal states.

Motion is limited to the cursor and a very low-amplitude status glow. Under `prefers-reduced-motion: reduce`, every animation is disabled and the cursor remains static.

There is no rapid flicker, automatic typing, parallax, moving grid, or animated noise.

## 5. Layout

### 5.1 Mobile-first shell

The primary viewport is a 320–430 px mobile browser opened after scanning the QR code.

The page contains one centered CRT shell with this hierarchy:

```text
FARPILOT // SECURE RELAY                    ● ONLINE
────────────────────────────────────────────────────
授权远程终端_
AUTHORIZE REMOTE TERMINAL

TARGET       Company DevBox
GATEWAY      gateway.example.com:22
KEY          SHA256:full-fingerprint

请与管理员提供的 SSH 指纹逐字比对。

DEVICE_NAME
[input]
[inline validation]

SSH_ED25519_PUBLIC_KEY
[textarea]
仅粘贴公钥。私钥始终保留在你的设备上。

[ AUTHORIZE DEVICE ]

AUTH WINDOW                                      04:32
[aria-live status]
```

The security metadata appears before the form. The full fingerprint is never truncated; it wraps at safe character boundaries while remaining copy-selectable.

### 5.2 Responsive behavior

At widths below 360 px:

- bezel and page margins shrink;
- metadata labels stack only if required;
- the button remains at least 44 px high;
- the textarea remains at least four lines high;
- no horizontal page scrolling is permitted.

At tablet/desktop widths:

- the CRT shell remains a focused card rather than expanding into a dashboard;
- maximum content width is approximately 560 px;
- vertical rhythm increases slightly;
- the same DOM order and state machine are preserved.

Long Host names wrap and cannot overlap status telemetry. The SSH fingerprint uses `overflow-wrap: anywhere` but is not visually abbreviated.

## 6. Language and copy

Chinese explains what the person must do. English terminal labels establish the product voice.

Examples:

```text
授权远程终端
AUTHORIZE REMOTE TERMINAL

请与管理员提供的 SSH 指纹逐字比对。

仅粘贴公钥。私钥始终保留在你的设备上。

设备已获得 Company DevBox 访问权限。
下一步：在 Moshi 中保存 SSH Profile，并再次核对指纹后连接。
```

Terminal statuses remain English:

```text
READY
AUTHORIZING...
PAIRING COMPLETE
SESSION EXPIRED
SESSION INVALID
TOO MANY ATTEMPTS
DEVICE NAME REJECTED
SSH KEY REJECTED
GATEWAY SYNC FAILED
SYSTEM ERROR
```

Technical identifiers such as `ssh-ed25519`, hostnames, usernames, ports, and SHA256 fingerprints are not translated.

## 7. Page states

### 7.1 State machine

```text
READY
  ├─ countdown reaches zero → EXPIRED
  ├─ submit → SUBMITTING
  │    ├─ client/server validation error → ERROR → READY
  │    ├─ rate limit / invalid session → TERMINAL_ERROR
  │    └─ 201 Created → SUCCESS
  └─ network failure → ERROR → READY
```

### 7.2 Ready

The form is enabled. `AUTH WINDOW` shows a monotonic countdown derived from the server-provided expiry timestamp.

### 7.3 Submitting

- inputs are disabled;
- the submit button reads `AUTHORIZING...`;
- duplicate submission is blocked;
- the countdown remains visible;
- no optimistic success state is displayed.

### 7.4 Field error

Field errors appear immediately below the related control and are announced through the status region.

```text
INVALID DEVICE NAME
仅支持 1–64 个非控制字符

INVALID SSH KEY
请输入完整的 ssh-ed25519 公钥
```

Client checks improve feedback only. Server validation remains authoritative.

### 7.5 Success

The existing card transforms in place; there is no redirect. The form is removed from the accessibility tree and replaced with:

```text
> validating ed25519 key... OK
> writing host grant... OK
> syncing authorized_keys... OK
> secure route ready... OK

PAIRING COMPLETE█

设备已获得 <Host> 访问权限。

HOST       gateway.example.com
PORT       22
USER       farpilot
VERIFY     SHA256:full-fingerprint

下一步：在 Moshi 中保存 SSH Profile，并再次核对指纹后连接。

SESSION SEALED // TOKEN CONSUMED
```

The log lines are displayed only after the server has returned `201 Created`, so they describe completed work rather than speculative progress.

There is no close button. The page tells the user that it is safe to close the browser.

### 7.6 Expired

When the countdown reaches zero:

- inputs and submit are disabled;
- the form is replaced or covered by `SESSION EXPIRED`;
- the page instructs the user to request or scan a new QR code;
- no request is sent automatically.

A server-side `pairing_not_found` response received during submission also transitions to a terminal invalid/expired state.

### 7.7 Generic browser errors

A GET request for an unknown, expired, or consumed token returns the same HTTP `404` and the same generic CRT page:

```text
SESSION INVALID
此配对会话不可用。请重新生成并扫描二维码。
```

It contains no Host name, token classification, timestamps, or existence signal.

Rate-limited browser GET requests return `429` and:

```text
TOO MANY ATTEMPTS
请求过于频繁，请稍后重试。
```

Internal browser GET errors return `500` and generic `SYSTEM ERROR` copy.

The JSON Claim API remains JSON and keeps its current status/error contract.

## 8. Implementation architecture

### 8.1 Self-contained compiled template

Create:

```text
crates/farpilot-gateway/src/pairing_page.html
```

`pairing_http.rs` embeds it through `include_str!()`. HTML, CSS, and JavaScript live in that one compiled asset. The browser requests no subresources.

A focused Rust renderer owns all substitutions. Its context contains only:

```text
host_display_name
gateway_host
gateway_port
ssh_host_fingerprint
expires_at_ms
claim_path
csp_nonce
initial_page_state
```

The renderer uses distinct text/attribute-safe encoding. Before substituting dynamic values, it validates the source template's token inventory: every allowlisted token appears exactly the required number of times and no unknown `{{FARPILOT_*}}` marker exists. Dynamic values are inserted in one pass and are never interpreted as template syntax, so user text that resembles a marker remains ordinary encoded text rather than causing a second substitution or false render failure.

The template does not evaluate arbitrary expressions and does not receive a serialized application object.

### 8.2 CSP nonce

Each HTML response generates a cryptographically random nonce and inserts it into exactly one `<style>` and one `<script>` element.

The response CSP is:

```text
default-src 'none';
style-src 'nonce-<nonce>';
script-src 'nonce-<nonce>';
connect-src 'self';
form-action 'self';
frame-ancestors 'none';
base-uri 'none'
```

The page also returns:

```text
Cache-Control: no-store
Referrer-Policy: no-referrer
X-Content-Type-Options: nosniff
X-Frame-Options: DENY
```

These are application response headers, not only Nginx headers, so direct loopback access retains the boundary.

### 8.3 Safe DOM updates

JavaScript reads initial values from encoded `data-*` attributes and writes all response values using `textContent`.

The script must not contain:

```text
innerHTML
eval
new Function
document.write
insertAdjacentHTML
```

Success rendering accepts only the existing response fields:

```text
device_id
host_id
ssh_host
ssh_port
ssh_username
ssh_host_fingerprint
```

No server error body is inserted verbatim. Known error codes map to fixed bilingual messages; unknown responses map to `SYSTEM ERROR`.

### 8.4 Countdown

The server injects an absolute expiry timestamp in milliseconds. The script computes remaining time from `Date.now()` and updates the display at most once per second.

The countdown:

- clamps at zero;
- formats `MM:SS` for the five-minute lifetime;
- expires immediately if the timestamp is already past;
- clears its timer on success or terminal error;
- does not extend the token lifetime;
- does not attempt to infer validity beyond server responses.

## 9. Security invariants

The redesign must preserve:

- one-time, five-minute, Host-scoped pairing tokens;
- generic behavior for unknown, expired, and consumed tokens;
- rate limiting by trusted client address;
- strict request body and name limits;
- Ed25519 public-key parsing and comment removal;
- transactional token consumption, device creation, and Host grant;
- `authorized_keys` synchronization or compensating device revocation;
- no private key, terminal payload, pairing token, or SSH public-key body in logs;
- no external resource requests from the token-bearing page;
- no Host metadata on an invalid-session page.

The visual redesign cannot weaken these invariants for convenience.

## 10. Accessibility

- Every input has a persistent `<label>`.
- Error text is connected with `aria-describedby`.
- Submission and page status use an `aria-live="polite"` region.
- Terminal error states use an appropriate heading and do not rely on color alone.
- Focus rings remain visible against the dark background.
- Touch controls are at least 44 px high.
- Text remains readable at 200% zoom.
- Scanlines use `pointer-events: none`.
- `prefers-reduced-motion: reduce` disables the cursor and glow animations.
- No animation flashes more than three times per second; the approved design uses no flicker.
- The tab order follows the visible form order.

## 11. Error handling

Claim response codes map to fixed presentation states:

| API error | UI status | Behavior |
|---|---|---|
| `invalid_device_name` | `DEVICE NAME REJECTED` | Re-enable form, focus device name |
| `invalid_ssh_public_key` | `SSH KEY REJECTED` | Re-enable form, focus public key |
| `pairing_not_found` | `SESSION INVALID` | Terminal state; keep form disabled |
| `device_revoked` | `DEVICE REVOKED` | Terminal state |
| `rate_limited` | `TOO MANY ATTEMPTS` | Terminal state with retry guidance |
| `authorized_keys_update_failed` | `GATEWAY SYNC FAILED` | Terminal state; the token was consumed and the compensating device revocation makes blind resubmission unsafe |
| `internal_error` or malformed response | `SYSTEM ERROR` | Generic retry guidance, no raw body |
| Fetch/network exception | `NETWORK ERROR` | Re-enable form if token has not expired |

Server status codes remain authoritative. JavaScript does not treat an HTTP 200 response as pairing success; success requires the existing `201 Created` response and a valid allowlisted response shape.

## 12. Testing strategy

### 12.1 Rust integration tests

Extend `crates/farpilot-gateway/tests/pairing_http.rs` to verify:

1. a valid page includes encoded Host, Gateway, full fingerprint, port, and expiry;
2. Host names containing `<script>`, quotes, ampersands, and attribute fragments never appear unescaped;
3. response CSP nonce matches the nonce on the one style and one script element;
4. `Cache-Control`, `Referrer-Policy`, `nosniff`, and frame denial headers are present;
5. the page contains no external script, stylesheet, font, image, iframe, or prefetch request;
6. unknown, expired, and consumed GET requests return the same `404` page state and no Host metadata;
7. rate-limited GET requests return themed `429` without token/Host disclosure;
8. internal GET failure returns generic themed `500`;
9. valid Claim behavior, key normalization, token consumption, and `authorized_keys` behavior remain unchanged;
10. the source template has an exact allowlisted token inventory, while dynamic text resembling a token remains literal text after one-pass rendering;
11. the body remains below a documented size ceiling.

Nonce values differ per response, so generic-page equivalence tests compare normalized DOM markers and public copy rather than raw bytes.

### 12.2 Static UI contract tests

Tests inspect the compiled template for:

```text
AUTH WINDOW
PAIRING COMPLETE
SESSION EXPIRED
SESSION INVALID
prefers-reduced-motion
aria-live
DEVICE_NAME
SSH_ED25519_PUBLIC_KEY
```

They reject:

```text
innerHTML
eval(
new Function
document.write
insertAdjacentHTML
http://
https://
<script src=
<link rel="stylesheet"
```

The external URL rejection applies to the HTML template, not comments in Rust tests.

### 12.3 Existing regression suites

Run:

```text
cargo fmt --all -- --check
cargo clippy --workspace --all-targets --all-features -- -D warnings
cargo test --workspace
cargo test --doc --workspace
```

All pairing, Gateway, installer, security, and release tests remain green.

### 12.4 Manual visual acceptance

Verify in a real mobile browser or responsive browser mode:

- 320 px viewport has no horizontal scrolling;
- iPhone Safari keyboard does not trap the submit control;
- long Host name and fingerprint wrap without truncation;
- a full Ed25519 public key can be pasted and edited;
- countdown reaches `00:00` and locks the form;
- success, expired, invalid, rate-limited, and network error states share the CRT language;
- CRT scanlines/glow do not reduce form readability;
- reduced-motion mode is static;
- focus order and focus rings are usable without a mouse.

## 13. Acceptance criteria

The redesign is complete only when:

1. the QR pairing page clearly presents the approved Retro CRT visual direction;
2. Chinese instructions and English terminal labels match this specification;
3. the security metadata precedes the form and the full fingerprint is readable;
4. the live countdown locks the form at expiry;
5. successful pairing transforms the card into `PAIRING COMPLETE` without redirect;
6. Moshi connection details and fingerprint appear in the success state;
7. browser GET errors use generic themed pages without Host-existence leakage;
8. the Claim API and server-side authorization behavior remain compatible;
9. every inline style/script is protected by the response CSP nonce;
10. the page makes no external resource requests;
11. reduced-motion, keyboard, touch, zoom, and mobile-width checks pass;
12. all automated tests and existing FarPilot CI pass with no warnings.
