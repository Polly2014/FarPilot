use std::fmt;

use base64::Engine;
use base64::engine::general_purpose::STANDARD;
use farpilot_core::frame::{ControlFrame, FrameCodec};
use farpilot_core::identity::HostIdentity;
use futures_util::{SinkExt, StreamExt};
use thiserror::Error;
use tokio::net::TcpStream;
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::{MaybeTlsStream, WebSocketStream, connect_async};
use url::Url;

use crate::reconnect::ReconnectPolicy;

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

pub struct AuthenticatedHostConnection {
    host_id: String,
    socket: WebSocketStream<MaybeTlsStream<TcpStream>>,
}

impl AuthenticatedHostConnection {
    pub fn host_id(&self) -> &str {
        &self.host_id
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
