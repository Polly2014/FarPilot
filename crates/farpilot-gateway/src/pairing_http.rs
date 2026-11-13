use std::collections::{HashMap, VecDeque};
use std::net::{IpAddr, SocketAddr};
use std::sync::{Arc, Mutex};
use std::time::{Instant, SystemTime};

use axum::extract::connect_info::ConnectInfo;
use axum::extract::rejection::JsonRejection;
use axum::extract::{Path, State};
use axum::http::{HeaderMap, StatusCode, header};
use axum::response::{Html, IntoResponse, Response};
use axum::routing::{get, post};
use axum::{Json, Router};
use base64::Engine;
use base64::engine::general_purpose::STANDARD;
use serde::{Deserialize, Serialize};

use crate::authorized_keys::{AuthorizedDeviceKey, write_authorized_keys};
use crate::config::GatewayConfig;
use crate::health;
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
        return error(StatusCode::TOO_MANY_REQUESTS, "rate_limited");
    }

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

    let host = escape_html(&preview.host_display_name);
    let ssh_host = escape_html(&state.config.public_ssh_host);
    let fingerprint = escape_html(&state.config.ssh_host_fingerprint);
    let action = format!("/v1/pair/{}/claim", escape_html(&secret));
    let html = format!(
        r#"<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width">
<title>Pair FarPilot device</title></head><body>
<main><h1>Pair with {host}</h1>
<p>SSH gateway: <code>{ssh_host}:{port}</code></p>
<p>Verify host fingerprint: <code>{fingerprint}</code></p>
<p><time data-expires-at-ms="{expires}">This pairing link expires shortly.</time></p>
<form id="pair-form"><label>Device name <input id="device-name" maxlength="64" required></label>
<label>SSH Ed25519 public key <textarea id="ssh-key" required></textarea></label>
<button type="submit">Pair device</button></form><pre id="result"></pre></main>
<script>
document.getElementById('pair-form').addEventListener('submit', async (event) => {{
 event.preventDefault();
 const response = await fetch('{action}', {{method:'POST', headers:{{'content-type':'application/json'}},
 body: JSON.stringify({{device_name:document.getElementById('device-name').value, ssh_public_key:document.getElementById('ssh-key').value}})}});
 document.getElementById('result').textContent = await response.text();
}});
</script></body></html>"#,
        port = state.config.public_ssh_port,
        expires = preview.expires_at_ms,
    );
    (
        StatusCode::OK,
        [(header::CONTENT_TYPE, "text/html; charset=utf-8")],
        Html(html),
    )
        .into_response()
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

fn escape_html(value: &str) -> String {
    value
        .replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
        .replace('\'', "&#39;")
}
