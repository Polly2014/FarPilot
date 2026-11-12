use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::time::{Duration, SystemTime};

use axum::body::{Body, to_bytes};
use axum::extract::connect_info::ConnectInfo;
use axum::http::{Request, StatusCode};
use base64::Engine;
use base64::engine::general_purpose::{STANDARD, URL_SAFE_NO_PAD};
use farpilot_core::pairing::PairingToken;
use farpilot_gateway::config::GatewayConfig;
use farpilot_gateway::pairing_http::{GatewayHttpState, build_router};
use farpilot_gateway::store::GatewayStore;
use serde_json::{Value, json};
use tower::ServiceExt;

async fn test_app() -> (axum::Router, GatewayStore, std::path::PathBuf) {
    let store = GatewayStore::connect("sqlite::memory:").await.unwrap();
    let authorized_keys_path =
        std::env::temp_dir().join(format!("farpilot-authorized-keys-{}", uuid::Uuid::new_v4()));
    let state = GatewayHttpState::new(
        store.clone(),
        GatewayConfig {
            public_ssh_host: "gateway.example.com".into(),
            public_ssh_port: 22,
            ssh_host_fingerprint: "SHA256:gateway-test".into(),
            authorized_keys_path: authorized_keys_path.clone(),
            pairing_failure_limit: 5,
            pairing_failure_window: Duration::from_secs(60),
        },
    );
    (build_router(state), store, authorized_keys_path)
}

fn request(method: &str, uri: &str, body: Body) -> Request<Body> {
    Request::builder()
        .method(method)
        .uri(uri)
        .header("content-type", "application/json")
        .extension(ConnectInfo(SocketAddr::new(
            IpAddr::V4(Ipv4Addr::LOCALHOST),
            50_000,
        )))
        .body(body)
        .unwrap()
}

async fn response_json(response: axum::response::Response) -> Value {
    let bytes = to_bytes(response.into_body(), 64 * 1024).await.unwrap();
    serde_json::from_slice(&bytes).unwrap()
}

fn host_public_key_b64() -> String {
    STANDARD.encode([9_u8; 32])
}

fn ssh_ed25519_key(comment: &str) -> String {
    let mut blob = Vec::new();
    blob.extend_from_slice(&(11_u32.to_be_bytes()));
    blob.extend_from_slice(b"ssh-ed25519");
    blob.extend_from_slice(&(32_u32.to_be_bytes()));
    blob.extend_from_slice(&[7_u8; 32]);
    format!("ssh-ed25519 {} {comment}", STANDARD.encode(blob))
}

#[tokio::test]
async fn host_enrollment_token_is_single_use() {
    let (app, store, _authorized_keys) = test_app().await;
    let now = SystemTime::now();
    let token = PairingToken::generate("operator", now, Duration::from_secs(300));
    store
        .insert_host_enrollment_token(token.record())
        .await
        .unwrap();
    let payload = json!({
        "enrollment_token": token.secret(),
        "display_name": "Company DevBox",
        "public_key_b64": host_public_key_b64()
    });

    let response = app
        .clone()
        .oneshot(request(
            "POST",
            "/v1/hosts/enroll",
            Body::from(payload.to_string()),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::CREATED);
    let response = response_json(response).await;
    assert!(response["host_id"].as_str().unwrap().starts_with("host_"));

    let replay = app
        .oneshot(request(
            "POST",
            "/v1/hosts/enroll",
            Body::from(payload.to_string()),
        ))
        .await
        .unwrap();
    assert_eq!(replay.status(), StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn valid_pairing_page_and_claim_normalize_the_ssh_key() {
    let (app, store, authorized_keys) = test_app().await;
    let host = store
        .enroll_host("Company DevBox", b"host-public-key")
        .await
        .unwrap();
    let now = SystemTime::now();
    let token = PairingToken::generate(&host.id, now, Duration::from_secs(300));
    store.insert_pairing_token(token.record()).await.unwrap();

    let page = app
        .clone()
        .oneshot(request(
            "GET",
            &format!("/pair/{}", token.secret()),
            Body::empty(),
        ))
        .await
        .unwrap();
    assert_eq!(page.status(), StatusCode::OK);
    let page_body = to_bytes(page.into_body(), 64 * 1024).await.unwrap();
    let page_body = String::from_utf8(page_body.to_vec()).unwrap();
    assert!(page_body.contains("Company DevBox"));
    assert!(page_body.contains("gateway.example.com"));
    assert!(page_body.contains("SHA256:gateway-test"));

    let payload = json!({
        "device_name": "Baoli iPhone",
        "ssh_public_key": ssh_ed25519_key("comment-is-discarded")
    });
    let claim = app
        .clone()
        .oneshot(request(
            "POST",
            &format!("/v1/pair/{}/claim", token.secret()),
            Body::from(payload.to_string()),
        ))
        .await
        .unwrap();
    assert_eq!(claim.status(), StatusCode::CREATED);
    let claim = response_json(claim).await;
    assert_eq!(claim["host_id"], host.id);
    assert_eq!(claim["ssh_host"], "gateway.example.com");
    assert_eq!(claim["ssh_username"], "farpilot");

    let paired_key = store
        .device_ssh_key(claim["device_id"].as_str().unwrap())
        .await
        .unwrap()
        .unwrap();
    assert!(!paired_key.contains("comment-is-discarded"));
    assert_eq!(paired_key.split_whitespace().count(), 2);
    let authorized = std::fs::read_to_string(&authorized_keys).unwrap();
    assert!(authorized.contains(claim["device_id"].as_str().unwrap()));
    assert!(authorized.contains(&paired_key));
    assert!(authorized.contains("restrict,command=\"/usr/local/bin/farpilot gateway attach"));
    let _ = std::fs::remove_file(authorized_keys);

    let consumed = app
        .oneshot(request(
            "GET",
            &format!("/pair/{}", token.secret()),
            Body::empty(),
        ))
        .await
        .unwrap();
    assert_eq!(consumed.status(), StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn invalid_expired_and_consumed_pairing_links_share_not_found() {
    let (app, store, _authorized_keys) = test_app().await;
    let host = store
        .enroll_host("Company DevBox", b"host-public-key")
        .await
        .unwrap();
    let expired = PairingToken::generate(
        &host.id,
        SystemTime::now() - Duration::from_secs(600),
        Duration::from_secs(300),
    );
    store.insert_pairing_token(expired.record()).await.unwrap();

    for secret in ["unknown-token", expired.secret()] {
        let response = app
            .clone()
            .oneshot(request("GET", &format!("/pair/{secret}"), Body::empty()))
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::NOT_FOUND);
        assert_eq!(response_json(response).await["error"], "pairing_not_found");
    }
}

#[tokio::test]
async fn pairing_rejects_large_bodies_unknown_fields_and_control_characters() {
    let (app, _store, _authorized_keys) = test_app().await;
    let too_large = app
        .clone()
        .oneshot(request(
            "POST",
            "/v1/pair/unknown/claim",
            Body::from(vec![b'x'; 16 * 1024 + 1]),
        ))
        .await
        .unwrap();
    assert_eq!(too_large.status(), StatusCode::PAYLOAD_TOO_LARGE);

    let unknown_field = json!({
        "device_name": "Phone",
        "ssh_public_key": ssh_ed25519_key("phone"),
        "admin": true
    });
    let response = app
        .clone()
        .oneshot(request(
            "POST",
            "/v1/pair/unknown/claim",
            Body::from(unknown_field.to_string()),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::BAD_REQUEST);

    let control_name = json!({
        "device_name": "Phone\nAdmin",
        "ssh_public_key": ssh_ed25519_key("phone")
    });
    let response = app
        .oneshot(request(
            "POST",
            "/v1/pair/unknown/claim",
            Body::from(control_name.to_string()),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn failed_pairing_lookups_are_rate_limited_per_address() {
    let (app, _store, _authorized_keys) = test_app().await;

    for attempt in 0..6 {
        let response = app
            .clone()
            .oneshot(request(
                "GET",
                &format!("/pair/{}", URL_SAFE_NO_PAD.encode([attempt; 32])),
                Body::empty(),
            ))
            .await
            .unwrap();
        let expected = if attempt < 5 {
            StatusCode::NOT_FOUND
        } else {
            StatusCode::TOO_MANY_REQUESTS
        };
        assert_eq!(response.status(), expected);
    }
}

#[tokio::test]
async fn health_endpoints_do_not_expose_registry_data() {
    let (app, _store, _authorized_keys) = test_app().await;

    for uri in ["/health/live", "/health/ready"] {
        let response = app
            .clone()
            .oneshot(request("GET", uri, Body::empty()))
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        let body = response_json(response).await;
        assert_eq!(body, json!({"status": "ok"}));
    }
}
