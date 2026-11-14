use std::collections::{HashMap, VecDeque};
use std::net::{IpAddr, SocketAddr};
use std::sync::{Arc, Mutex};
use std::time::{Instant, SystemTime};

use axum::extract::connect_info::ConnectInfo;
use axum::extract::rejection::JsonRejection;
use axum::extract::{Path, State};
use axum::http::{HeaderMap, HeaderName, HeaderValue, StatusCode, header};
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post};
use axum::{Json, Router};
use base64::Engine;
use base64::engine::general_purpose::STANDARD;
use serde::{Deserialize, Serialize};

use crate::authorized_keys::{AuthorizedDeviceKey, write_authorized_keys};
use crate::config::GatewayConfig;
use crate::health;
use crate::pairing_page::{PairingPageContext, PairingPageState, render_pairing_page};
use crate::store::{GatewayStore, StoreError};

const MAX_REQUEST_BODY_BYTES: usize = 16 * 1024;

#[derive(Clone)]
pub struct GatewayHttpState {
    store: GatewayStore,
    config: GatewayConfig,
    failures: Arc<Mutex<HashMap<IpAddr, VecDeque<Instant>>>>,
}

impl GatewayHttpState {
    pub fn new(store: GatewayStore, config: GatewayConfig) -> Self {
        Self {
            store,
            config,
            failures: Arc::new(Mutex::new(HashMap::new())),
        }
    }

    fn is_rate_limited(&self, address: IpAddr) -> bool {
        let now = Instant::now();
        let mut failures = self
            .failures
            .lock()
            .unwrap_or_else(|error| error.into_inner());
        let attempts = failures.entry(address).or_default();
        while attempts.front().is_some_and(|attempt| {
            now.duration_since(*attempt) >= self.config.pairing_failure_window
        }) {
            attempts.pop_front();
        }
        attempts.len() >= self.config.pairing_failure_limit
    }

    fn record_failure(&self, address: IpAddr) {
        let mut failures = self
            .failures
            .lock()
            .unwrap_or_else(|error| error.into_inner());
        failures
            .entry(address)
            .or_default()
            .push_back(Instant::now());
    }
}

fn client_address(peer: SocketAddr, headers: &HeaderMap) -> IpAddr {
    if !peer.ip().is_loopback() {
        return peer.ip();
    }
    headers
        .get("x-real-ip")
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.parse().ok())
        .unwrap_or_else(|| peer.ip())
}

pub fn build_router(state: GatewayHttpState) -> Router {
    Router::new()
        .route("/v1/hosts/enroll", post(enroll_host))
        .route("/pair/{secret}", get(pairing_page))
        .route("/v1/pair/{secret}/claim", post(claim_device))
        .route("/health/live", get(health::live))
        .route("/health/ready", get(ready))
        .layer(axum::extract::DefaultBodyLimit::max(MAX_REQUEST_BODY_BYTES))
        .with_state(state)
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct EnrollHostRequest {
    enrollment_token: String,
    display_name: String,
    public_key_b64: String,
}

#[derive(Serialize)]
struct EnrollHostResponse {
    host_id: String,
    display_name: String,
}

async fn enroll_host(
    State(state): State<GatewayHttpState>,
    payload: Result<Json<EnrollHostRequest>, JsonRejection>,
) -> Response {
    let Json(payload) = match payload {
        Ok(payload) => payload,
        Err(rejection) => return json_rejection(rejection),
    };
    let display_name = match validated_name(&payload.display_name) {
        Some(name) => name,
        None => return error(StatusCode::BAD_REQUEST, "invalid_display_name"),
    };
    let public_key = match parse_host_public_key(&payload.public_key_b64) {
        Some(key) => key,
        None => return error(StatusCode::BAD_REQUEST, "invalid_host_public_key"),
    };

    match state
        .store
        .consume_host_enrollment_token_and_enroll(
            &payload.enrollment_token,
            &display_name,
            &public_key,
            SystemTime::now(),
        )
        .await
    {
        Ok(host) => (
            StatusCode::CREATED,
            Json(EnrollHostResponse {
                host_id: host.id,
                display_name: host.display_name,
            }),
        )
            .into_response(),
        Err(StoreError::InvalidPairingToken) => {
            error(StatusCode::NOT_FOUND, "enrollment_not_found")
        }
        Err(_) => error(StatusCode::INTERNAL_SERVER_ERROR, "internal_error"),
    }
}

async fn pairing_page(
    State(state): State<GatewayHttpState>,
    ConnectInfo(peer): ConnectInfo<SocketAddr>,
    headers: HeaderMap,
    Path(secret): Path<String>,
) -> Response {
    let address = client_address(peer, &headers);
    if state.is_rate_limited(address) {
        return browser_page(StatusCode::TOO_MANY_REQUESTS, PairingPageState::RateLimited);
    }

    let preview = match state
        .store
        .pairing_preview(&secret, SystemTime::now())
        .await
    {
        Ok(Some(preview)) => preview,
        Ok(None) => {
            state.record_failure(address);
            return browser_page(StatusCode::NOT_FOUND, PairingPageState::Invalid);
        }
        Err(_) => {
            return browser_page(
                StatusCode::INTERNAL_SERVER_ERROR,
                PairingPageState::InternalError,
            );
        }
    };

    let expires_at_ms = match u64::try_from(preview.expires_at_ms) {
        Ok(expires_at_ms) => expires_at_ms,
        Err(_) => {
            return browser_page(
                StatusCode::INTERNAL_SERVER_ERROR,
                PairingPageState::InternalError,
            );
        }
    };

    browser_page(
        StatusCode::OK,
        PairingPageState::Ready(PairingPageContext {
            host_display_name: preview.host_display_name,
            gateway_host: state.config.public_ssh_host.clone(),
            gateway_port: state.config.public_ssh_port,
            ssh_host_fingerprint: state.config.ssh_host_fingerprint.clone(),
            expires_at_ms,
            claim_path: format!("/v1/pair/{secret}/claim"),
        }),
    )
}

fn browser_page(status: StatusCode, state: PairingPageState) -> Response {
    let rendered = match render_pairing_page(state) {
        Ok(rendered) => rendered,
        Err(_) => return browser_render_failure(),
    };
    let csp = match HeaderValue::from_str(&rendered.csp) {
        Ok(csp) => csp,
        Err(_) => return browser_render_failure(),
    };
    let mut response = (
        status,
        [(header::CONTENT_TYPE, "text/html; charset=utf-8")],
        rendered.body,
    )
        .into_response();
    apply_browser_headers(response.headers_mut(), csp);
    response
}

fn browser_render_failure() -> Response {
    let mut response = (
        StatusCode::INTERNAL_SERVER_ERROR,
        [(header::CONTENT_TYPE, "text/plain; charset=utf-8")],
        "Pairing page unavailable",
    )
        .into_response();
    apply_browser_headers(
        response.headers_mut(),
        HeaderValue::from_static("default-src 'none'; frame-ancestors 'none'; base-uri 'none'"),
    );
    response
}

fn apply_browser_headers(headers: &mut HeaderMap, csp: HeaderValue) {
    headers.insert(header::CACHE_CONTROL, HeaderValue::from_static("no-store"));
    headers.insert(
        HeaderName::from_static("referrer-policy"),
        HeaderValue::from_static("no-referrer"),
    );
    headers.insert(
        HeaderName::from_static("x-content-type-options"),
        HeaderValue::from_static("nosniff"),
    );
    headers.insert(
        HeaderName::from_static("x-frame-options"),
        HeaderValue::from_static("DENY"),
    );
    headers.insert(HeaderName::from_static("content-security-policy"), csp);
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ClaimDeviceRequest {
    device_name: String,
    ssh_public_key: String,
}

#[derive(Serialize)]
struct ClaimDeviceResponse {
    device_id: String,
    host_id: String,
    ssh_host: String,
    ssh_port: u16,
    ssh_username: &'static str,
    ssh_host_fingerprint: String,
}

async fn claim_device(
    State(state): State<GatewayHttpState>,
    ConnectInfo(peer): ConnectInfo<SocketAddr>,
    headers: HeaderMap,
    Path(secret): Path<String>,
    payload: Result<Json<ClaimDeviceRequest>, JsonRejection>,
) -> Response {
    let address = client_address(peer, &headers);
    if state.is_rate_limited(address) {
        return error(StatusCode::TOO_MANY_REQUESTS, "rate_limited");
    }
    let Json(payload) = match payload {
        Ok(payload) => payload,
        Err(rejection) => return json_rejection(rejection),
    };
    let device_name = match validated_name(&payload.device_name) {
        Some(name) => name,
        None => return error(StatusCode::BAD_REQUEST, "invalid_device_name"),
    };
    let ssh_public_key = match parse_ssh_ed25519_key(&payload.ssh_public_key) {
        Some(key) => key,
        None => return error(StatusCode::BAD_REQUEST, "invalid_ssh_public_key"),
    };
    let preview = match state
        .store
        .pairing_preview(&secret, SystemTime::now())
        .await
    {
        Ok(Some(preview)) => preview,
        Ok(None) => {
            state.record_failure(address);
            return error(StatusCode::NOT_FOUND, "pairing_not_found");
        }
        Err(_) => return error(StatusCode::INTERNAL_SERVER_ERROR, "internal_error"),
    };

    match state
        .store
        .consume_pairing_token_and_add_device(
            &secret,
            &device_name,
            &ssh_public_key,
            SystemTime::now(),
        )
        .await
    {
        Ok(device) => {
            if sync_authorized_keys(&state).await.is_err() {
                let _ = state.store.revoke_device(&device.id).await;
                return error(
                    StatusCode::INTERNAL_SERVER_ERROR,
                    "authorized_keys_update_failed",
                );
            }
            (
                StatusCode::CREATED,
                Json(ClaimDeviceResponse {
                    device_id: device.id,
                    host_id: preview.host_id,
                    ssh_host: state.config.public_ssh_host.clone(),
                    ssh_port: state.config.public_ssh_port,
                    ssh_username: "farpilot",
                    ssh_host_fingerprint: state.config.ssh_host_fingerprint.clone(),
                }),
            )
                .into_response()
        }
        Err(StoreError::InvalidPairingToken) => {
            state.record_failure(address);
            error(StatusCode::NOT_FOUND, "pairing_not_found")
        }
        Err(StoreError::DeviceRevoked) => error(StatusCode::FORBIDDEN, "device_revoked"),
        Err(_) => error(StatusCode::INTERNAL_SERVER_ERROR, "internal_error"),
    }
}

async fn sync_authorized_keys(state: &GatewayHttpState) -> Result<(), ()> {
    let keys = state
        .store
        .list_active_devices()
        .await
        .map_err(|_| ())?
        .into_iter()
        .map(|device| AuthorizedDeviceKey {
            device_id: device.id,
            ssh_public_key: device.ssh_public_key,
        })
        .collect::<Vec<_>>();
    write_authorized_keys(&state.config.authorized_keys_path, &keys).map_err(|_| ())
}

async fn ready(State(state): State<GatewayHttpState>) -> Response {
    health::readiness(state.store.is_ready().await)
}

#[derive(Serialize)]
struct ErrorBody {
    error: &'static str,
}

fn json_rejection(rejection: JsonRejection) -> Response {
    let status = rejection.status();
    if status == StatusCode::PAYLOAD_TOO_LARGE {
        error(status, "payload_too_large")
    } else {
        error(StatusCode::BAD_REQUEST, "invalid_request")
    }
}

fn error(status: StatusCode, code: &'static str) -> Response {
    (status, Json(ErrorBody { error: code })).into_response()
}

fn validated_name(value: &str) -> Option<String> {
    let value = value.trim();
    let length = value.chars().count();
    (length > 0 && length <= 64 && !value.chars().any(char::is_control)).then(|| value.to_owned())
}

fn parse_host_public_key(value: &str) -> Option<Vec<u8>> {
    let decoded = STANDARD.decode(value).ok()?;
    (decoded.len() == 32 && STANDARD.encode(&decoded) == value).then_some(decoded)
}

fn parse_ssh_ed25519_key(value: &str) -> Option<String> {
    let mut fields = value.split_whitespace();
    if fields.next()? != "ssh-ed25519" {
        return None;
    }
    let encoded = fields.next()?;
    let blob = STANDARD.decode(encoded).ok()?;
    if STANDARD.encode(&blob) != encoded {
        return None;
    }

    let mut offset = 0;
    let algorithm = read_ssh_string(&blob, &mut offset)?;
    let key = read_ssh_string(&blob, &mut offset)?;
    if algorithm != b"ssh-ed25519" || key.len() != 32 || offset != blob.len() {
        return None;
    }
    Some(format!("ssh-ed25519 {encoded}"))
}

fn read_ssh_string<'a>(blob: &'a [u8], offset: &mut usize) -> Option<&'a [u8]> {
    let length_bytes: [u8; 4] = blob.get(*offset..*offset + 4)?.try_into().ok()?;
    *offset += 4;
    let length = usize::try_from(u32::from_be_bytes(length_bytes)).ok()?;
    let value = blob.get(*offset..*offset + length)?;
    *offset += length;
    Some(value)
}

#[cfg(test)]
mod browser_response_tests {
    use axum::body::to_bytes;
    use axum::http::header;

    use super::{PairingPageState, StatusCode, browser_page, browser_render_failure};

    #[tokio::test]
    async fn internal_error_browser_page_is_generic_and_hardened() {
        let response = browser_page(
            StatusCode::INTERNAL_SERVER_ERROR,
            PairingPageState::InternalError,
        );
        assert_eq!(response.status(), StatusCode::INTERNAL_SERVER_ERROR);
        assert_eq!(response.headers()[header::CACHE_CONTROL], "no-store");
        assert_eq!(response.headers()["referrer-policy"], "no-referrer");
        let body = to_bytes(response.into_body(), 128 * 1024).await.unwrap();
        let body = String::from_utf8(body.to_vec()).unwrap();
        assert!(body.contains("SYSTEM ERROR"));
        assert!(!body.contains("gateway.example.com"));
    }

    #[tokio::test]
    async fn render_failure_fallback_has_no_sensitive_context() {
        let response = browser_render_failure();
        assert_eq!(response.status(), StatusCode::INTERNAL_SERVER_ERROR);
        assert_eq!(
            response.headers()[header::CONTENT_TYPE],
            "text/plain; charset=utf-8"
        );
        assert_eq!(response.headers()[header::CACHE_CONTROL], "no-store");
        let body = to_bytes(response.into_body(), 1024).await.unwrap();
        assert_eq!(&body[..], b"Pairing page unavailable");
    }
}
