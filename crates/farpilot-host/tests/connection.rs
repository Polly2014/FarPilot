use std::io;
use std::net::SocketAddr;
use std::path::PathBuf;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use async_trait::async_trait;
use base64::Engine;
use base64::engine::general_purpose::STANDARD;
use bytes::Bytes;
use farpilot_core::frame::{ControlFrame, FrameCodec};
use farpilot_core::identity::HostIdentity;
use farpilot_gateway::broker::AttachEvent;
use farpilot_gateway::host_ws::{HostWsState, build_host_ws_router};
use farpilot_gateway::store::GatewayStore;
use farpilot_host::client::{ConnectionErrorKind, HostClient, TransportSecurity};
use farpilot_host::herdr::{HerdrConfig, HerdrLaunch};
use farpilot_host::identity_store::{FileIdentityStore, IdentityProtector};
use farpilot_host::pty::{PtyFactory, PtySession};
use farpilot_host::reconnect::ReconnectPolicy;
use futures_util::{SinkExt, StreamExt};
use tempfile::tempdir;
use tokio_tungstenite::connect_async;
use tokio_tungstenite::tungstenite::Message;

struct XorProtector;

impl IdentityProtector for XorProtector {
    fn protect(&self, plaintext: &[u8]) -> io::Result<Vec<u8>> {
        Ok(plaintext.iter().map(|byte| byte ^ 0xA5).collect())
    }

    fn unprotect(&self, ciphertext: &[u8]) -> io::Result<Vec<u8>> {
        self.protect(ciphertext)
    }
}

struct TrackingPty {
    closed: AtomicBool,
    read_wake: tokio::sync::Notify,
    closed_notify: tokio::sync::Notify,
}

#[async_trait]
impl PtySession for TrackingPty {
    async fn write_input(&self, _bytes: &[u8]) -> anyhow::Result<()> {
        Ok(())
    }

    async fn read_output(&self, _maximum: usize) -> anyhow::Result<Bytes> {
        self.read_wake.notified().await;
        Ok(Bytes::new())
    }

    async fn resize(&self, _cols: u16, _rows: u16) -> anyhow::Result<()> {
        Ok(())
    }

    async fn close(&self) -> anyhow::Result<()> {
        self.closed.store(true, Ordering::SeqCst);
        self.read_wake.notify_waiters();
        self.closed_notify.notify_waiters();
        Ok(())
    }
}

struct TrackingFactory {
    pty: Arc<TrackingPty>,
    spawned: Arc<tokio::sync::Notify>,
}

#[async_trait]
impl PtyFactory for TrackingFactory {
    async fn spawn_herdr(&self, _request: HerdrLaunch) -> anyhow::Result<Arc<dyn PtySession>> {
        self.spawned.notify_waiters();
        Ok(self.pty.clone())
    }
}

#[test]
fn identity_store_round_trips_without_plaintext_secret() {
    let directory = tempdir().unwrap();
    let path = directory.path().join("host-identity.json");
    let store = FileIdentityStore::new(path.clone(), XorProtector);

    let first = store.load_or_create().unwrap();
    let secret = first.to_secret_bytes();
    let stored = std::fs::read(&path).unwrap();
    assert!(
        !stored
            .windows(secret.len())
            .any(|window| window == &secret[..])
    );

    let second = store.load_or_create().unwrap();
    assert_eq!(first.public_key(), second.public_key());
}

#[tokio::test(start_paused = true)]
async fn reconnect_delay_is_exponential_and_capped() {
    let policy = ReconnectPolicy::without_jitter(
        Duration::from_secs(1),
        Duration::from_secs(120),
        Duration::from_secs(60),
    );
    assert_eq!(policy.delay_for_attempt(0), Duration::from_secs(1));
    assert_eq!(policy.delay_for_attempt(1), Duration::from_secs(2));
    assert_eq!(policy.delay_for_attempt(7), Duration::from_secs(120));
    assert_eq!(policy.delay_for_attempt(20), Duration::from_secs(120));

    let sleeper = tokio::spawn({
        let policy = policy.clone();
        async move { policy.sleep_before_retry(0).await }
    });
    tokio::time::advance(Duration::from_millis(999)).await;
    assert!(!sleeper.is_finished());
    tokio::time::advance(Duration::from_millis(1)).await;
    sleeper.await.unwrap();

    assert!(!policy.should_reset_after(Duration::from_secs(59)));
    assert!(policy.should_reset_after(Duration::from_secs(60)));
}

async fn spawn_gateway(store: GatewayStore) -> (String, tokio::task::JoinHandle<io::Result<()>>) {
    let app = build_host_ws_router(HostWsState::new(store));
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address: SocketAddr = listener.local_addr().unwrap();
    let server = tokio::spawn(async move {
        axum::serve(
            listener,
            app.into_make_service_with_connect_info::<SocketAddr>(),
        )
        .await
    });
    (format!("ws://{address}/ws/host"), server)
}

#[tokio::test]
async fn host_proof_deadline_closes_an_incomplete_handshake() {
    let store = GatewayStore::connect("sqlite::memory:").await.unwrap();
    let identity = HostIdentity::generate();
    let host = store
        .enroll_host("Company DevBox", &identity.public_key().to_bytes())
        .await
        .unwrap();
    let state = HostWsState::new(store).with_handshake_timeout(Duration::from_millis(20));
    let app = build_host_ws_router(state);
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let server = tokio::spawn(async move {
        axum::serve(
            listener,
            app.into_make_service_with_connect_info::<SocketAddr>(),
        )
        .await
    });
    let (mut socket, _) = connect_async(format!("ws://{address}/ws/host"))
        .await
        .unwrap();
    let hello = FrameCodec::encode_control(&ControlFrame::HostHello {
        host_id: host.id,
        public_key: STANDARD.encode(identity.public_key().to_bytes()),
    })
    .unwrap();
    socket
        .send(Message::Text(String::from_utf8(hello).unwrap().into()))
        .await
        .unwrap();
    let challenge = socket.next().await.unwrap().unwrap();
    assert!(matches!(challenge, Message::Text(_)));

    let closed = tokio::time::timeout(Duration::from_secs(1), socket.next())
        .await
        .expect("Gateway should close after the proof deadline");
    assert!(matches!(
        closed,
        None | Some(Ok(Message::Close(_))) | Some(Err(_))
    ));
    server.abort();
}

#[tokio::test]
async fn host_authenticates_with_challenge_response() {
    let store = GatewayStore::connect("sqlite::memory:").await.unwrap();
    let identity = HostIdentity::generate();
    let host = store
        .enroll_host("Company DevBox", &identity.public_key().to_bytes())
        .await
        .unwrap();
    let secret = identity.to_secret_bytes();
    let client_identity = HostIdentity::from_secret_bytes(&secret);
    let (url, server) = spawn_gateway(store).await;

    let connection = HostClient::new(
        &url,
        host.id.clone(),
        client_identity,
        TransportSecurity::AllowInsecureLoopback,
    )
    .unwrap()
    .connect_once()
    .await
    .unwrap();

    assert_eq!(connection.host_id(), host.id);
    connection.close().await.unwrap();
    server.abort();
}

#[tokio::test]
async fn wrong_host_key_is_a_permanent_authentication_failure() {
    let store = GatewayStore::connect("sqlite::memory:").await.unwrap();
    let enrolled = HostIdentity::generate();
    let host = store
        .enroll_host("Company DevBox", &enrolled.public_key().to_bytes())
        .await
        .unwrap();
    let (url, server) = spawn_gateway(store).await;

    let error = HostClient::new(
        &url,
        host.id,
        HostIdentity::generate(),
        TransportSecurity::AllowInsecureLoopback,
    )
    .unwrap()
    .connect_once()
    .await
    .unwrap_err();

    assert_eq!(error.kind(), ConnectionErrorKind::Permanent);
    server.abort();
}

#[tokio::test]
async fn authenticated_replacement_closes_the_previous_connection() {
    let store = GatewayStore::connect("sqlite::memory:").await.unwrap();
    let identity = HostIdentity::generate();
    let secret = identity.to_secret_bytes();
    let host = store
        .enroll_host("Company DevBox", &identity.public_key().to_bytes())
        .await
        .unwrap();
    let (url, server) = spawn_gateway(store).await;
    let first = HostClient::new(
        &url,
        host.id.clone(),
        HostIdentity::from_secret_bytes(&secret),
        TransportSecurity::AllowInsecureLoopback,
    )
    .unwrap()
    .connect_once()
    .await
    .unwrap();
    let second = HostClient::new(
        &url,
        host.id,
        HostIdentity::from_secret_bytes(&secret),
        TransportSecurity::AllowInsecureLoopback,
    )
    .unwrap()
    .connect_once()
    .await
    .unwrap();

    tokio::time::timeout(Duration::from_secs(1), first.wait_closed())
        .await
        .expect("superseded connection should close")
        .unwrap();
    second.close().await.unwrap();
    server.abort();
}

#[tokio::test]
async fn gateway_disconnect_closes_all_active_host_pty_sessions() {
    let store = GatewayStore::connect("sqlite::memory:").await.unwrap();
    let identity = HostIdentity::generate();
    let secret = identity.to_secret_bytes();
    let host = store
        .enroll_host("Company DevBox", &identity.public_key().to_bytes())
        .await
        .unwrap();
    let device = store
        .add_device("Baoli MacBook", "ssh-ed25519 AAAATEST")
        .await
        .unwrap();
    store.grant_device(&device.id, &host.id).await.unwrap();

    let state = HostWsState::new(store);
    let broker = state.broker();
    let app = build_host_ws_router(state);
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let server = tokio::spawn(async move {
        axum::serve(
            listener,
            app.into_make_service_with_connect_info::<SocketAddr>(),
        )
        .await
    });
    let url = format!("ws://{address}/ws/host");

    let first = HostClient::new(
        &url,
        host.id.clone(),
        HostIdentity::from_secret_bytes(&secret),
        TransportSecurity::AllowInsecureLoopback,
    )
    .unwrap()
    .connect_once()
    .await
    .unwrap();
    let pty = Arc::new(TrackingPty {
        closed: AtomicBool::new(false),
        read_wake: tokio::sync::Notify::new(),
        closed_notify: tokio::sync::Notify::new(),
    });
    let spawned = Arc::new(tokio::sync::Notify::new());
    let factory: Arc<dyn PtyFactory> = Arc::new(TrackingFactory {
        pty: pty.clone(),
        spawned: spawned.clone(),
    });
    let config = HerdrConfig::new(PathBuf::from("herdr"), None).unwrap();
    let first_runtime = tokio::spawn(first.run_with_factory(config, factory));

    tokio::time::timeout(Duration::from_secs(1), async {
        while !broker.is_host_online(&host.id).await {
            tokio::task::yield_now().await;
        }
    })
    .await
    .expect("Host should register with the broker");
    let spawned_session = spawned.notified();
    let mut attach = broker.open(&device.id, &host.id, 80, 24).await.unwrap();
    tokio::time::timeout(Duration::from_secs(1), spawned_session)
        .await
        .expect("Host should spawn the PTY session");
    assert_eq!(attach.recv().await, Some(AttachEvent::Opened));

    let closed = pty.closed_notify.notified();
    let replacement = HostClient::new(
        &url,
        host.id,
        HostIdentity::from_secret_bytes(&secret),
        TransportSecurity::AllowInsecureLoopback,
    )
    .unwrap()
    .connect_once()
    .await
    .unwrap();
    tokio::time::timeout(Duration::from_secs(1), first_runtime)
        .await
        .expect("superseded Host runtime should stop")
        .unwrap()
        .unwrap();
    tokio::time::timeout(Duration::from_millis(100), closed)
        .await
        .expect("disconnect must close the active PTY session");
    assert!(pty.closed.load(Ordering::SeqCst));

    replacement.close().await.unwrap();
    server.abort();
}

#[tokio::test]
async fn persistent_host_reconnects_after_pairing_connection_replaces_it() {
    let store = GatewayStore::connect("sqlite::memory:").await.unwrap();
    let identity = HostIdentity::generate();
    let secret = identity.to_secret_bytes();
    let host = store
        .enroll_host("Company DevBox", &identity.public_key().to_bytes())
        .await
        .unwrap();
    let state = HostWsState::new(store).with_pairing_base_url("https://gateway.example.com");
    let broker = state.broker();
    let app = build_host_ws_router(state);
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let server = tokio::spawn(async move {
        axum::serve(
            listener,
            app.into_make_service_with_connect_info::<SocketAddr>(),
        )
        .await
    });
    let url = format!("ws://{address}/ws/host");
    let connected = Arc::new(tokio::sync::Notify::new());
    let connected_task = connected.clone();
    let persistent_url = url.clone();
    let persistent_host_id = host.id.clone();
    let persistent_secret = secret.clone();
    let factory: Arc<dyn PtyFactory> = Arc::new(TrackingFactory {
        pty: Arc::new(TrackingPty {
            closed: AtomicBool::new(false),
            read_wake: tokio::sync::Notify::new(),
            closed_notify: tokio::sync::Notify::new(),
        }),
        spawned: Arc::new(tokio::sync::Notify::new()),
    });
    let persistent = tokio::spawn(async move {
        for attempt in 0..2 {
            if attempt > 0 {
                tokio::time::sleep(Duration::from_millis(100)).await;
            }
            let connection = HostClient::new(
                &persistent_url,
                persistent_host_id.clone(),
                HostIdentity::from_secret_bytes(&persistent_secret),
                TransportSecurity::AllowInsecureLoopback,
            )
            .unwrap()
            .connect_once()
            .await
            .unwrap();
            connected_task.notify_one();
            connection
                .run_with_factory(
                    HerdrConfig::new(PathBuf::from("herdr"), None).unwrap(),
                    factory.clone(),
                )
                .await
                .unwrap();
        }
    });

    tokio::time::timeout(Duration::from_secs(1), connected.notified())
        .await
        .expect("persistent Host should connect");
    let mut pairing = HostClient::new(
        &url,
        host.id.clone(),
        HostIdentity::from_secret_bytes(&secret),
        TransportSecurity::AllowInsecureLoopback,
    )
    .unwrap()
    .connect_once()
    .await
    .unwrap();
    let invitation = pairing.create_pairing().await.unwrap();
    assert!(
        invitation
            .pairing_url
            .starts_with("https://gateway.example.com/pair/")
    );
    pairing.close().await.unwrap();

    tokio::time::timeout(Duration::from_secs(2), connected.notified())
        .await
        .expect("persistent Host should reconnect after pairing command exits");
    assert!(broker.is_host_online(&host.id).await);

    persistent.abort();
    server.abort();
}

#[test]
fn reconnect_jitter_stays_inside_the_configured_bound() {
    let policy = ReconnectPolicy::with_jitter(
        Duration::from_secs(10),
        Duration::from_secs(120),
        Duration::from_secs(60),
        0.2,
    );

    assert_eq!(
        policy.delay_for_attempt_with_sample(0, 0.0),
        Duration::from_secs(8)
    );
    assert_eq!(
        policy.delay_for_attempt_with_sample(0, 1.0),
        Duration::from_secs(12)
    );
    assert_eq!(
        policy.delay_for_attempt_with_sample(20, 1.0),
        Duration::from_secs(120)
    );
}

#[test]
fn insecure_non_loopback_gateway_is_rejected() {
    let result = HostClient::new(
        "ws://example.com/ws/host",
        "host_123".into(),
        HostIdentity::generate(),
        TransportSecurity::AllowInsecureLoopback,
    );

    assert!(result.is_err());
}
