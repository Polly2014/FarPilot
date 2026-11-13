use std::fmt;

use base64::Engine;
use base64::engine::general_purpose::STANDARD;
use bytes::Bytes;
use farpilot_core::frame::{ControlFrame, FrameCodec, SessionCloseReason};
use farpilot_core::identity::HostIdentity;
use farpilot_core::limits::MAX_CHANNELS_PER_HOST;
use futures_util::{SinkExt, StreamExt};
use thiserror::Error;
use tokio::net::TcpStream;
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::{MaybeTlsStream, WebSocketStream, connect_async};
use url::Url;

use crate::herdr::HerdrConfig;
use crate::pty::{PortablePtyFactory, PtyFactory};
use crate::reconnect::ReconnectPolicy;
use crate::session::{HostSessionError, HostSessionRegistry, drive_session};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum TransportSecurity {
    RequireTls,
    AllowInsecureLoopback,
}

pub struct HostClient {
    url: Url,
    host_id: String,
    identity: HostIdentity,
}

impl HostClient {
    pub fn new(
        url: &str,
        host_id: String,
        identity: HostIdentity,
        security: TransportSecurity,
    ) -> Result<Self, ConnectionError> {
        let url = Url::parse(url).map_err(|_| ConnectionError::permanent("invalid Gateway URL"))?;
        if url.query().is_some() || url.fragment().is_some() {
            return Err(ConnectionError::permanent(
                "Gateway URL must not contain query credentials or fragments",
            ));
        }
        let secure = url.scheme() == "wss";
        let insecure_loopback = url.scheme() == "ws"
            && matches!(security, TransportSecurity::AllowInsecureLoopback)
            && matches!(url.host_str(), Some("127.0.0.1" | "localhost" | "::1"));
        if !secure && !insecure_loopback {
            return Err(ConnectionError::permanent(
                "Gateway URL must use wss except for loopback tests",
            ));
        }
        Ok(Self {
            url,
            host_id,
            identity,
        })
    }

    pub async fn connect_once(&self) -> Result<AuthenticatedHostConnection, ConnectionError> {
        let (mut socket, _) = connect_async(self.url.as_str())
            .await
            .map_err(|error| ConnectionError::transient(error.to_string()))?;
        send_control(
            &mut socket,
            &ControlFrame::HostHello {
                host_id: self.host_id.clone(),
                public_key: STANDARD.encode(self.identity.public_key().to_bytes()),
            },
        )
        .await?;

        let challenge = receive_control(&mut socket).await?;
        let ControlFrame::HostChallenge { challenge, .. } = challenge else {
            return Err(ConnectionError::permanent(
                "Gateway refused Host authentication",
            ));
        };
        let challenge = STANDARD
            .decode(challenge)
            .map_err(|_| ConnectionError::permanent("Gateway challenge is malformed"))?;
        let challenge: [u8; 32] = challenge
            .try_into()
            .map_err(|_| ConnectionError::permanent("Gateway challenge has invalid length"))?;
        let proof = self.identity.sign_challenge(&self.host_id, &challenge);
        send_control(
            &mut socket,
            &ControlFrame::HostProof {
                host_id: self.host_id.clone(),
                signature: STANDARD.encode(proof.to_bytes()),
            },
        )
        .await?;

        match receive_control(&mut socket).await? {
            ControlFrame::HostReady { host_id } if host_id == self.host_id => {
                Ok(AuthenticatedHostConnection {
                    host_id: self.host_id.clone(),
                    socket,
                })
            }
            _ => Err(ConnectionError::permanent("Gateway rejected Host proof")),
        }
    }

    pub async fn connect_until_authenticated(
        &self,
        policy: &ReconnectPolicy,
    ) -> Result<AuthenticatedHostConnection, ConnectionError> {
        let mut attempt = 0;
        loop {
            match self.connect_once().await {
                Ok(connection) => return Ok(connection),
                Err(error) if error.kind() == ConnectionErrorKind::Permanent => return Err(error),
                Err(_) => {
                    policy.sleep_before_retry(attempt).await;
                    attempt = attempt.saturating_add(1);
                }
            }
        }
    }
}

enum RuntimeEvent {
    Output(uuid::Uuid, Bytes),
    Exited(uuid::Uuid, i32),
}

pub struct PairingInvitation {
    pub pairing_url: String,
    pub secret: String,
    pub expires_at_ms: u64,
}

pub struct AuthenticatedHostConnection {
    host_id: String,
    socket: WebSocketStream<MaybeTlsStream<TcpStream>>,
}

impl AuthenticatedHostConnection {
    pub fn host_id(&self) -> &str {
        &self.host_id
    }

    pub async fn create_pairing(&mut self) -> Result<PairingInvitation, ConnectionError> {
        let request_id = uuid::Uuid::new_v4();
        send_control(
            &mut self.socket,
            &ControlFrame::PairingCreate { request_id },
        )
        .await?;
        match receive_control(&mut self.socket).await? {
            ControlFrame::PairingCreated {
                request_id: response_id,
                pairing_url,
                secret,
                expires_at_ms,
            } if response_id == request_id => Ok(PairingInvitation {
                pairing_url,
                secret,
                expires_at_ms,
            }),
            _ => Err(ConnectionError::permanent(
                "Gateway returned an unexpected pairing response",
            )),
        }
    }

    pub async fn run_herdr(self, config: HerdrConfig) -> Result<(), ConnectionError> {
        self.run_with_factory(config, std::sync::Arc::new(PortablePtyFactory))
            .await
    }

    pub async fn run_with_factory(
        self,
        config: HerdrConfig,
        factory: std::sync::Arc<dyn PtyFactory>,
    ) -> Result<(), ConnectionError> {
        let registry = HostSessionRegistry::new(MAX_CHANNELS_PER_HOST);
        let (runtime_tx, mut runtime_rx) = tokio::sync::mpsc::channel(64);
        let (mut sink, mut stream) = self.socket.split();
        let mut session_tasks = tokio::task::JoinSet::new();
        let result: Result<(), ConnectionError> = async {
            loop {
                tokio::select! {
                    incoming = stream.next() => {
                        let Some(incoming) = incoming else { return Ok(()); };
                        let message = incoming.map_err(|error| ConnectionError::transient(error.to_string()))?;
                        match message {
                            Message::Text(text) => {
                                let frame = FrameCodec::decode_control(text.as_bytes())
                                    .map_err(|error| ConnectionError::permanent(error.to_string()))?;
                                match frame {
                                    ControlFrame::SessionOpen { channel_id, cols, rows, .. } => {
                                        match registry.open(channel_id).await {
                                            Ok(handle) => {
                                                send_sink_control(&mut sink, &ControlFrame::SessionOpened { channel_id }).await?;
                                                let factory = factory.clone();
                                                let registry = registry.clone();
                                                let config = config.clone();
                                                let runtime_tx = runtime_tx.clone();
                                                session_tasks.spawn(async move {
                                                    let (output_tx, mut output_rx) = tokio::sync::mpsc::channel(16);
                                                    let forward = tokio::spawn({
                                                        let runtime_tx = runtime_tx.clone();
                                                        async move {
                                                            while let Some(bytes) = output_rx.recv().await {
                                                                if runtime_tx.send(RuntimeEvent::Output(channel_id, bytes)).await.is_err() {
                                                                    break;
                                                                }
                                                            }
                                                        }
                                                    });
                                                    let result = drive_session(factory, config.launch(cols, rows), handle, output_tx).await;
                                                    forward.abort();
                                                    registry.finish(channel_id).await;
                                                    let exit_code = result.as_ref().map(|_| 0).unwrap_or(1);
                                                    let _ = runtime_tx.send(RuntimeEvent::Exited(channel_id, exit_code)).await;
                                                });
                                            }
                                            Err(_) => {
                                                send_sink_control(&mut sink, &ControlFrame::SessionRefused {
                                                    channel_id,
                                                    reason: farpilot_core::frame::SessionRefusalReason::LimitExceeded,
                                                }).await?;
                                            }
                                        }
                                    }
                                    ControlFrame::TerminalResize { channel_id, cols, rows } => {
                                        if let Err(error) = registry.resize(channel_id, cols, rows).await
                                            && let Some(reason) = input_failure_close_reason(error)
                                        {
                                            let _ = registry.close(channel_id, reason).await;
                                            send_sink_control(&mut sink, &ControlFrame::SessionClose {
                                                channel_id,
                                                reason,
                                            }).await?;
                                        }
                                    }
                                    ControlFrame::SessionClose { channel_id, reason } => {
                                        let _ = registry.close(channel_id, reason).await;
                                    }
                                    ControlFrame::Ping { nonce } => {
                                        send_sink_control(&mut sink, &ControlFrame::Pong { nonce }).await?;
                                    }
                                    _ => {}
                                }
                            }
                            Message::Binary(bytes) => {
                                let frame = FrameCodec::decode_terminal(&bytes)
                                    .map_err(|error| ConnectionError::permanent(error.to_string()))?;
                                if let Err(error) = registry.input(frame.channel_id, &frame.payload).await
                                    && let Some(reason) = input_failure_close_reason(error)
                                {
                                    let _ = registry.close(frame.channel_id, reason).await;
                                    send_sink_control(&mut sink, &ControlFrame::SessionClose {
                                        channel_id: frame.channel_id,
                                        reason,
                                    }).await?;
                                }
                            }
                            Message::Close(_) => return Ok(()),
                            _ => {}
                        }
                    }
                    event = runtime_rx.recv() => {
                        match event {
                            Some(RuntimeEvent::Output(channel_id, bytes)) => {
                                let encoded = FrameCodec::encode_terminal(channel_id, &bytes)
                                    .map_err(|error| ConnectionError::permanent(error.to_string()))?;
                                sink.send(Message::Binary(encoded.into())).await
                                    .map_err(|error| ConnectionError::transient(error.to_string()))?;
                            }
                            Some(RuntimeEvent::Exited(channel_id, exit_code)) => {
                                send_sink_control(&mut sink, &ControlFrame::SessionExited {
                                    channel_id,
                                    exit_code: Some(exit_code),
                                }).await?;
                            }
                            None => return Ok(()),
                        }
                    }
                    completed = session_tasks.join_next(), if !session_tasks.is_empty() => {
                        if let Some(Err(error)) = completed {
                            return Err(ConnectionError::transient(format!("Host session task failed: {error}")));
                        }
                    }
                }
            }
        }
        .await;

        drop(runtime_rx);
        drop(runtime_tx);
        registry
            .close_all(SessionCloseReason::HostDisconnected)
            .await;
        while let Some(completed) = session_tasks.join_next().await {
            if let Err(error) = completed {
                return Err(ConnectionError::transient(format!(
                    "Host session task failed during disconnect: {error}"
                )));
            }
        }
        result
    }

    pub async fn close(mut self) -> Result<(), ConnectionError> {
        self.socket
            .close(None)
            .await
            .map_err(|error| ConnectionError::transient(error.to_string()))
    }

    pub async fn wait_closed(mut self) -> Result<(), ConnectionError> {
        while let Some(message) = self.socket.next().await {
            match message {
                Ok(Message::Close(_)) => return Ok(()),
                Ok(_) => {}
                Err(error) => return Err(ConnectionError::transient(error.to_string())),
            }
        }
        Ok(())
    }
}

impl fmt::Debug for AuthenticatedHostConnection {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("AuthenticatedHostConnection")
            .field("host_id", &self.host_id)
            .finish_non_exhaustive()
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ConnectionErrorKind {
    Transient,
    Permanent,
}

#[derive(Debug, Error)]
#[error("{message}")]
pub struct ConnectionError {
    kind: ConnectionErrorKind,
    message: String,
}

impl ConnectionError {
    pub fn kind(&self) -> ConnectionErrorKind {
        self.kind
    }

    fn transient(message: impl Into<String>) -> Self {
        Self {
            kind: ConnectionErrorKind::Transient,
            message: message.into(),
        }
    }

    fn permanent(message: impl Into<String>) -> Self {
        Self {
            kind: ConnectionErrorKind::Permanent,
            message: message.into(),
        }
    }
}

fn input_failure_close_reason(error: HostSessionError) -> Option<SessionCloseReason> {
    match error {
        HostSessionError::QueueFull => Some(SessionCloseReason::SlowConsumer),
        _ => None,
    }
}

async fn send_sink_control<S>(sink: &mut S, frame: &ControlFrame) -> Result<(), ConnectionError>
where
    S: futures_util::Sink<Message, Error = tokio_tungstenite::tungstenite::Error> + Unpin,
{
    let bytes = FrameCodec::encode_control(frame)
        .map_err(|error| ConnectionError::permanent(error.to_string()))?;
    let text = String::from_utf8(bytes)
        .map_err(|_| ConnectionError::permanent("control frame was not UTF-8"))?;
    sink.send(Message::Text(text.into()))
        .await
        .map_err(|error| ConnectionError::transient(error.to_string()))
}

async fn send_control(
    socket: &mut WebSocketStream<MaybeTlsStream<TcpStream>>,
    frame: &ControlFrame,
) -> Result<(), ConnectionError> {
    let bytes = FrameCodec::encode_control(frame)
        .map_err(|error| ConnectionError::permanent(error.to_string()))?;
    let text = String::from_utf8(bytes)
        .map_err(|_| ConnectionError::permanent("control frame was not UTF-8"))?;
    socket
        .send(Message::Text(text.into()))
        .await
        .map_err(|error| ConnectionError::transient(error.to_string()))
}

async fn receive_control(
    socket: &mut WebSocketStream<MaybeTlsStream<TcpStream>>,
) -> Result<ControlFrame, ConnectionError> {
    let message = socket
        .next()
        .await
        .ok_or_else(|| ConnectionError::permanent("Gateway closed during authentication"))?
        .map_err(|error| ConnectionError::transient(error.to_string()))?;
    match message {
        Message::Text(text) => FrameCodec::decode_control(text.as_bytes())
            .map_err(|error| ConnectionError::permanent(error.to_string())),
        _ => Err(ConnectionError::permanent(
            "Gateway sent a non-control authentication frame",
        )),
    }
}

#[cfg(test)]
mod tests {
    use farpilot_core::frame::SessionCloseReason;

    use crate::session::HostSessionError;

    #[test]
    fn full_input_queue_closes_only_the_overloaded_session() {
        assert_eq!(
            super::input_failure_close_reason(HostSessionError::QueueFull),
            Some(SessionCloseReason::SlowConsumer)
        );
        assert_eq!(
            super::input_failure_close_reason(HostSessionError::UnknownChannel),
            None
        );
    }
}
