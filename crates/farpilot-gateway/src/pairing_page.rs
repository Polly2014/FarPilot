use base64::Engine;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use rand::RngCore;
use rand::rngs::OsRng;
use thiserror::Error;

const TEMPLATE: &str = include_str!("pairing_page.html");
const RESERVED_PREFIX: &str = "{{FARPILOT_";
const TEMPLATE_TOKENS: &[(&str, usize)] = &[
    ("{{FARPILOT_NONCE}}", 2),
    ("{{FARPILOT_PAGE_STATE}}", 1),
    ("{{FARPILOT_HOST_TEXT}}", 1),
    ("{{FARPILOT_GATEWAY_TEXT}}", 1),
    ("{{FARPILOT_PORT_TEXT}}", 1),
    ("{{FARPILOT_FINGERPRINT_TEXT}}", 1),
    ("{{FARPILOT_EXPIRES_ATTR}}", 1),
    ("{{FARPILOT_CLAIM_PATH_ATTR}}", 1),
];

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

pub fn render_pairing_page(
    state: PairingPageState,
) -> Result<RenderedPairingPage, PairingPageRenderError> {
    validate_template_tokens(TEMPLATE, TEMPLATE_TOKENS)?;

    let mut random = [0_u8; 16];
    OsRng.fill_bytes(&mut random);
    let nonce = URL_SAFE_NO_PAD.encode(random);

    let (page_state, context) = match state {
        PairingPageState::Ready(context) => ("READY", Some(context)),
        PairingPageState::Invalid => ("SESSION INVALID", None),
        PairingPageState::RateLimited => ("TOO MANY ATTEMPTS", None),
        PairingPageState::InternalError => ("SYSTEM ERROR", None),
    };
    let context = context.as_ref();
    let values = [
        ("{{FARPILOT_NONCE}}", nonce.clone()),
        ("{{FARPILOT_PAGE_STATE}}", page_state.to_owned()),
        (
            "{{FARPILOT_HOST_TEXT}}",
            escape_html(context.map_or("", |value| &value.host_display_name)),
        ),
        (
            "{{FARPILOT_GATEWAY_TEXT}}",
            escape_html(context.map_or("", |value| &value.gateway_host)),
        ),
        (
            "{{FARPILOT_PORT_TEXT}}",
            context
                .map(|value| value.gateway_port.to_string())
                .unwrap_or_default(),
        ),
        (
            "{{FARPILOT_FINGERPRINT_TEXT}}",
            escape_html(context.map_or("", |value| &value.ssh_host_fingerprint)),
        ),
        (
            "{{FARPILOT_EXPIRES_ATTR}}",
            context
                .map(|value| value.expires_at_ms.to_string())
                .unwrap_or_default(),
        ),
        (
            "{{FARPILOT_CLAIM_PATH_ATTR}}",
            escape_html(context.map_or("", |value| &value.claim_path)),
        ),
    ];
    let body = render_template(TEMPLATE, &values)?;
    let csp = format!(
        "default-src 'none'; style-src 'nonce-{nonce}'; script-src 'nonce-{nonce}'; connect-src 'self'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'"
    );
    Ok(RenderedPairingPage { body, nonce, csp })
}

fn escape_html(value: &str) -> String {
    value
        .replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
        .replace('\'', "&#39;")
}

fn render_template(
    template: &str,
    values: &[(&str, String)],
) -> Result<String, PairingPageRenderError> {
    let mut rendered = String::with_capacity(template.len() + 256);
    let mut cursor = 0;
    while let Some(relative_start) = template[cursor..].find(RESERVED_PREFIX) {
        let start = cursor + relative_start;
        let relative_end = template[start..]
            .find("}}")
            .ok_or(PairingPageRenderError::InvalidTemplateTokens)?;
        let end = start + relative_end + 2;
        let token = &template[start..end];
        let replacement = values
            .iter()
            .find_map(|(candidate, value)| (*candidate == token).then_some(value))
            .ok_or(PairingPageRenderError::InvalidTemplateTokens)?;
        rendered.push_str(&template[cursor..start]);
        rendered.push_str(replacement);
        cursor = end;
    }
    rendered.push_str(&template[cursor..]);
    Ok(rendered)
}

fn validate_template_tokens(
    template: &str,
    expected: &[(&str, usize)],
) -> Result<(), PairingPageRenderError> {
    for (token, count) in expected {
        if template.matches(token).count() != *count {
            return Err(PairingPageRenderError::InvalidTemplateTokens);
        }
    }
    let mut without_known_tokens = template.to_owned();
    for (token, _) in expected {
        without_known_tokens = without_known_tokens.replace(token, "");
    }
    if without_known_tokens.contains(RESERVED_PREFIX) {
        return Err(PairingPageRenderError::InvalidTemplateTokens);
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::{
        PairingPageContext, PairingPageRenderError, PairingPageState, TEMPLATE,
        render_pairing_page, validate_template_tokens,
    };

    const TOKENS: &[(&str, usize)] = &[
        ("{{FARPILOT_NONCE}}", 2),
        ("{{FARPILOT_PAGE_STATE}}", 1),
        ("{{FARPILOT_HOST_TEXT}}", 1),
        ("{{FARPILOT_GATEWAY_TEXT}}", 1),
        ("{{FARPILOT_PORT_TEXT}}", 1),
        ("{{FARPILOT_FINGERPRINT_TEXT}}", 1),
        ("{{FARPILOT_EXPIRES_ATTR}}", 1),
        ("{{FARPILOT_CLAIM_PATH_ATTR}}", 1),
    ];

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
    fn ready_page_escapes_text_and_attributes_and_resolves_tokens() {
        let mut value = context();
        value.host_display_name = "<script>alert(1)</script> & \"host\"".into();
        value.claim_path = "/v1/pair/a'b\"c/claim".into();

        let page = render_pairing_page(PairingPageState::Ready(value)).unwrap();

        assert!(
            page.body
                .contains("&lt;script&gt;alert(1)&lt;/script&gt; &amp; &quot;host&quot;")
        );
        assert!(!page.body.contains("<script>alert(1)</script>"));
        assert!(page.body.contains("a&#39;b&quot;c"));
        for (token, _) in TOKENS {
            assert!(!page.body.contains(token));
        }
    }

    #[test]
    fn each_page_has_one_style_and_script_with_the_same_fresh_nonce() {
        let first = render_pairing_page(PairingPageState::Ready(context())).unwrap();
        let second = render_pairing_page(PairingPageState::Ready(context())).unwrap();

        assert_ne!(first.nonce, second.nonce);
        assert_eq!(
            first
                .body
                .matches(&format!("nonce=\"{}\"", first.nonce))
                .count(),
            2
        );
        assert!(
            first
                .csp
                .contains(&format!("style-src 'nonce-{}'", first.nonce))
        );
        assert!(
            first
                .csp
                .contains(&format!("script-src 'nonce-{}'", first.nonce))
        );
    }

    #[test]
    fn invalid_page_has_no_ready_metadata() {
        let page = render_pairing_page(PairingPageState::Invalid).unwrap();

        assert!(page.body.contains("SESSION INVALID"));
        assert!(!page.body.contains("Company DevBox"));
        assert!(!page.body.contains("gateway.example.com"));
        assert!(!page.body.contains("SHA256:gateway-test"));
    }

    #[test]
    fn generic_error_states_are_distinct_without_ready_metadata() {
        let rate_limited = render_pairing_page(PairingPageState::RateLimited).unwrap();
        let internal = render_pairing_page(PairingPageState::InternalError).unwrap();

        assert!(rate_limited.body.contains("TOO MANY ATTEMPTS"));
        assert!(internal.body.contains("SYSTEM ERROR"));
        for body in [&rate_limited.body, &internal.body] {
            assert!(!body.contains("Company DevBox"));
            assert!(!body.contains("gateway.example.com"));
        }
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
    fn template_validation_rejects_missing_duplicate_and_unknown_tokens() {
        let valid = "{{FARPILOT_A}} {{FARPILOT_B}}";
        let tokens = [("{{FARPILOT_A}}", 1), ("{{FARPILOT_B}}", 1)];
        assert_eq!(validate_template_tokens(valid, &tokens), Ok(()));
        assert_eq!(
            validate_template_tokens("{{FARPILOT_A}}", &tokens),
            Err(PairingPageRenderError::InvalidTemplateTokens)
        );
        assert_eq!(
            validate_template_tokens("{{FARPILOT_A}} {{FARPILOT_A}} {{FARPILOT_B}}", &tokens),
            Err(PairingPageRenderError::InvalidTemplateTokens)
        );
        assert_eq!(
            validate_template_tokens(
                "{{FARPILOT_A}} {{FARPILOT_B}} {{FARPILOT_UNKNOWN}}",
                &tokens
            ),
            Err(PairingPageRenderError::InvalidTemplateTokens)
        );
    }

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
            "<form id=\"pair-form\"",
            "<label for=\"device-name\"",
            "<input id=\"device-name\"",
            "<label for=\"ssh-key\"",
            "<textarea id=\"ssh-key\"",
            "<button id=\"submit-button\"",
            "<dl class=\"connection-data\"",
            "<section id=\"terminal-state\" hidden",
            "overflow-wrap: anywhere",
            "pointer-events: none",
        ] {
            assert!(TEMPLATE.contains(required), "missing {required}");
        }
        assert!(!TEMPLATE.contains("onclick="));
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
            "<img ",
            "<iframe ",
            "<link rel=\"prefetch\"",
        ] {
            assert!(!TEMPLATE.contains(forbidden), "forbidden {forbidden}");
        }
    }

    #[test]
    fn template_contains_pairing_state_machine_contract() {
        for required in [
            "function setUiState(",
            "function updateCountdown(",
            "function expireSession(",
            "function setFieldError(",
            "function clearErrors(",
            "function mapApiError(",
            "function renderSuccess(",
            "function renderTerminalError(",
            "function validClaimPath(",
            "async function submitPairing(",
            "Date.now()",
            "setInterval(updateCountdown, 1000)",
            "new AbortController()",
            "fetch(",
            "response.status === 201",
            "response.json()",
            ".textContent",
        ] {
            assert!(TEMPLATE.contains(required), "missing {required}");
        }
        for required in [
            "invalid_device_name",
            "invalid_ssh_public_key",
            "pairing_not_found",
            "device_revoked",
            "rate_limited",
            "authorized_keys_update_failed",
            "internal_error",
            "DEVICE NAME REJECTED",
            "SSH KEY REJECTED",
            "SESSION INVALID",
            "DEVICE REVOKED",
            "TOO MANY ATTEMPTS",
            "GATEWAY SYNC FAILED",
            "SYSTEM ERROR",
            "NETWORK ERROR",
            "SESSION EXPIRED",
            "PAIRING COMPLETE",
        ] {
            assert!(TEMPLATE.contains(required), "missing {required}");
        }
    }

    #[test]
    fn api_error_mapping_rejects_prototype_and_non_string_codes() {
        for required in [
            "Object.create(null)",
            "typeof code !== 'string'",
            "Object.prototype.hasOwnProperty.call(errors, code)",
            "return errors.internal_error",
        ] {
            assert!(TEMPLATE.contains(required), "missing {required}");
        }
        assert!(!TEMPLATE.contains("return errors[code] ||"));
        for poisoned in ["toString:", "constructor:", "__proto__:"] {
            assert!(!TEMPLATE.contains(poisoned), "poisoned map key {poisoned}");
        }
    }

    #[test]
    fn template_has_visible_request_error_lifecycle() {
        for required in [
            "id=\"request-error\"",
            "class=\"request-error\"",
            "role=\"alert\"",
            "const requestError = document.getElementById('request-error')",
            "function setRequestError(",
            "function clearRequestError(",
            "setRequestError('NETWORK ERROR'",
            "网络连接失败，请检查连接后重试。",
        ] {
            assert!(TEMPLATE.contains(required), "missing {required}");
        }
        assert!(
            TEMPLATE.matches("clearRequestError();").count() >= 4,
            "request errors must be cleared on validation, resubmit, success, and terminal transitions"
        );
    }

    #[test]
    fn device_name_validation_counts_unicode_scalars_like_the_server() {
        assert!(!TEMPLATE.contains("maxlength=\"64\""));
        for required in [
            "function validDeviceName(deviceName)",
            "const deviceNameLength = Array.from(deviceName).length",
            "deviceNameLength >= 1 && deviceNameLength <= 64",
        ] {
            assert!(TEMPLATE.contains(required), "missing {required}");
        }
    }

    #[test]
    fn success_renderer_uses_only_allowlisted_connection_fields() {
        for required in [
            "ssh_host",
            "ssh_port",
            "ssh_username",
            "ssh_host_fingerprint",
        ] {
            assert!(TEMPLATE.contains(required), "missing {required}");
        }
        for forbidden in ["device_id", "host_id"] {
            assert!(!TEMPLATE.contains(forbidden), "forbidden {forbidden}");
        }
    }

    #[test]
    fn rendered_ready_page_stays_below_size_ceiling() {
        let page = render_pairing_page(PairingPageState::Ready(context())).unwrap();
        assert!(
            page.body.len() < 96 * 1024,
            "page was {} bytes",
            page.body.len()
        );
    }

    #[test]
    fn minimal_template_has_no_external_resources() {
        let page = render_pairing_page(PairingPageState::Ready(context())).unwrap();

        for forbidden in [
            "<script src=",
            "<link rel=\"stylesheet\"",
            "http://",
            "https://",
            "<img ",
            "<iframe ",
        ] {
            assert!(!page.body.contains(forbidden), "forbidden {forbidden}");
        }
    }
}
