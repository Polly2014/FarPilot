use std::collections::HashMap;
use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use axum::Router;
use axum::extract::State;
use axum::extract::ws::{Message, WebSocket, WebSocketUpgrade};
use axum::response::Response;
use axum::routing::get;
use base64::Engine;
use base64::engine::general_purpose::STANDARD;
use ed25519_dalek::VerifyingKey;
use farpilot_core::frame::{ControlFrame, FrameCodec, TerminalFrame};
use farpilot_core::identity::HostProof;
use futures_util::{SinkExt, StreamExt};
use rand::RngCore;
use rand::rngs::OsRng;
use tokio::sync::{Mutex, watch};
use uuid::Uuid;

use crate::broker::{HostCommand, SessionBroker};
use crate::store::GatewayStore;

const HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(10);

type ActiveHost = (Uuid, watch::Sender<bool>);
type ActiveHosts = Arc<Mutex<HashMap<String, ActiveHost>>>;

#[derive(Clone)]
pub struct HostWsState {
    store: GatewayStore,
    broker: SessionBroker,
    active: ActiveHosts,
    handshake_timeout: Duration,
}

impl HostWsState {
    pub fn new(store: GatewayStore) -> Self {
        Self {
            broker: SessionBroker::new(store.clone()),
            store,
            active: Arc::new(Mutex::new(HashMap::new())),
            handshake_timeout: HANDSHAKE_TIMEOUT,
        }
    }

    pub fn with_handshake_timeout(mut self, timeout: Duration) -> Self {
        self.handshake_timeout = timeout;
        self
    }

    pub fn broker(&self) -> SessionBroker {
        self.broker.clone()
    }
}

pub fn build_host_ws_router(state: HostWsState) -> Router {
    Router::new()
        .route("/ws/host", get(upgrade_host))
        .with_state(state)
}

async fn upgrade_host(State(state): State<HostWsState>, upgrade: WebSocketUpgrade) -> Response {
    upgrade.on_upgrade(move |socket| handle_host(socket, state))
}

async fn handle_host(mut socket: WebSocket, state: HostWsState) {
    let Some(ControlFrame::HostHello {
        host_id,
        public_key,
    }) = receive_control(&mut socket, state.handshake_timeout).await
    else {
        let _ = socket.close().await;
        return;
    };

    let Some(enrolled_key) = state.store.host_public_key(&host_id).await.ok().flatten() else {
        let _ = socket.close().await;
        return;
    };
    let Ok(hello_key) = STANDARD.decode(public_key) else {
        let _ = socket.close().await;
        return;
    };
    if hello_key != enrolled_key {
        let _ = socket.close().await;
        return;
    }

    let mut challenge = [0_u8; 32];
    OsRng.fill_bytes(&mut challenge);
    let expires_at_ms = system_time_ms(SystemTime::now() + state.handshake_timeout);
    if send_control(
        &mut socket,
        &ControlFrame::HostChallenge {
            challenge: STANDARD.encode(challenge),
            expires_at_ms,
        },
    )
    .await
    .is_err()
    {
        return;
    }

    let Some(ControlFrame::HostProof {
        host_id: proof_host_id,
        signature,
    }) = receive_control(&mut socket, state.handshake_timeout).await
    else {
        let _ = socket.close().await;
        return;
    };
    if proof_host_id != host_id {
        let _ = socket.close().await;
        return;
    }
    let Ok(public_key): Result<[u8; 32], _> = enrolled_key.as_slice().try_into() else {
        let _ = socket.close().await;
        return;
    };
    let Ok(public_key) = VerifyingKey::from_bytes(&public_key) else {
        let _ = socket.close().await;
        return;
    };
    let Ok(signature): Result<Vec<u8>, _> = STANDARD.decode(signature) else {
        let _ = socket.close().await;
        return;
    };
    let Ok(signature): Result<[u8; 64], _> = signature.try_into() else {
        let _ = socket.close().await;
        return;
    };
    let proof = HostProof::from_bytes(&signature);
    if HostProof::verify(public_key, &host_id, &challenge, &proof).is_err()
        || SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|duration| duration.as_millis() > u128::from(expires_at_ms))
            .unwrap_or(true)
    {
        let _ = socket.close().await;
        return;
    }

    let generation = Uuid::new_v4();
    let (cancel_tx, mut cancel_rx) = watch::channel(false);
    if let Some((_, previous)) = state
        .active
        .lock()
        .await
        .insert(host_id.clone(), (generation, cancel_tx))
    {
        let _ = previous.send(true);
    }
    if send_control(
        &mut socket,
        &ControlFrame::HostReady {
            host_id: host_id.clone(),
        },
    )
    .await
    .is_err()
    {
        remove_generation(&state, &host_id, generation).await;
        return;
    }

    let mut registered = state.broker.register_host(&host_id).await;
    loop {
        tokio::select! {
            changed = cancel_rx.changed() => {
                if changed.is_ok() && *cancel_rx.borrow() {
                    close_gracefully(&mut socket).await;
                }
                break;
            }
            command = registered.recv() => {
                let result = match command {
                    Some(HostCommand::Control(frame)) => send_control(&mut socket, &frame).await,
                    Some(HostCommand::Terminal(frame)) => send_terminal(&mut socket, &frame).await,
                    None => {
                        close_gracefully(&mut socket).await;
                        break;
                    }
                };
                if result.is_err() {
                    break;
                }
            }
            message = socket.next() => {
                match message {
                    Some(Ok(Message::Text(text))) => {
                        match FrameCodec::decode_control(text.as_bytes()) {
                            Ok(ControlFrame::Ping { nonce }) => {
                                let _ = send_control(&mut socket, &ControlFrame::Pong { nonce }).await;
                            }
                            Ok(frame) => {
                                let _ = registered.send_control(frame).await;
                            }
                            Err(_) => break,
                        }
                    }
                    Some(Ok(Message::Binary(bytes))) => {
                        let Ok(frame) = FrameCodec::decode_terminal(&bytes) else { break; };
                        let _ = registered.send_terminal(frame).await;
                    }
                    Some(Ok(Message::Close(_))) | None | Some(Err(_)) => break,
                    _ => {}
                }
            }
        }
    }
    registered.disconnect().await;
    remove_generation(&state, &host_id, generation).await;
}

async fn close_gracefully(socket: &mut WebSocket) {
    let _ = socket.send(Message::Close(None)).await;
    let _ = tokio::time::timeout(Duration::from_millis(100), socket.next()).await;
}

async fn receive_control(socket: &mut WebSocket, timeout: Duration) -> Option<ControlFrame> {
    let message = tokio::time::timeout(timeout, socket.next())
        .await
        .ok()??
        .ok()?;
    match message {
        Message::Text(text) => FrameCodec::decode_control(text.as_bytes()).ok(),
        _ => None,
    }
}

async fn send_control(socket: &mut WebSocket, frame: &ControlFrame) -> Result<(), ()> {
    let bytes = FrameCodec::encode_control(frame).map_err(|_| ())?;
    let text = String::from_utf8(bytes).map_err(|_| ())?;
    socket
        .send(Message::Text(text.into()))
        .await
        .map_err(|_| ())
}

async fn send_terminal(socket: &mut WebSocket, frame: &TerminalFrame) -> Result<(), ()> {
    let bytes = FrameCodec::encode_terminal(frame.channel_id, &frame.payload).map_err(|_| ())?;
    socket
        .send(Message::Binary(bytes.into()))
        .await
        .map_err(|_| ())
}

async fn remove_generation(state: &HostWsState, host_id: &str, generation: Uuid) {
    let mut active = state.active.lock().await;
    if active
        .get(host_id)
        .is_some_and(|(current, _)| *current == generation)
    {
        active.remove(host_id);
    }
}

fn system_time_ms(time: SystemTime) -> u64 {
    time.duration_since(UNIX_EPOCH)
        .map(|duration| u64::try_from(duration.as_millis()).unwrap_or(u64::MAX))
        .unwrap_or(0)
}
