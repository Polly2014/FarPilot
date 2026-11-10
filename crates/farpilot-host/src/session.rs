use std::collections::HashMap;
use std::fmt;
use std::sync::Arc;

use bytes::Bytes;
use farpilot_core::frame::SessionCloseReason;
use thiserror::Error;
use tokio::sync::{Mutex, mpsc};
use uuid::Uuid;

use crate::herdr::HerdrLaunch;
use crate::pty::PtyFactory;

const SESSION_EVENT_CAPACITY: usize = 64;
const PTY_READ_MAXIMUM: usize = 64 * 1024;

#[derive(Clone)]
pub struct HostSessionRegistry {
    maximum: usize,
    sessions: Arc<Mutex<HashMap<Uuid, mpsc::Sender<HostSessionEvent>>>>,
}

impl HostSessionRegistry {
    pub fn new(maximum: usize) -> Self {
        Self {
            maximum,
            sessions: Arc::new(Mutex::new(HashMap::new())),
        }
    }

    pub async fn open(&self, channel_id: Uuid) -> Result<HostSessionHandle, HostSessionError> {
        let mut sessions = self.sessions.lock().await;
        if sessions.contains_key(&channel_id) {
            return Err(HostSessionError::DuplicateChannel);
        }
        if sessions.len() >= self.maximum {
            return Err(HostSessionError::LimitExceeded);
        }
        let (sender, receiver) = mpsc::channel(SESSION_EVENT_CAPACITY);
        sessions.insert(channel_id, sender);
        Ok(HostSessionHandle {
            channel_id,
            receiver,
        })
    }

    pub async fn input(&self, channel_id: Uuid, bytes: &[u8]) -> Result<(), HostSessionError> {
        self.send(
            channel_id,
            HostSessionEvent::Input(Bytes::copy_from_slice(bytes)),
        )
        .await
    }

    pub async fn resize(
        &self,
        channel_id: Uuid,
        cols: u16,
        rows: u16,
    ) -> Result<(), HostSessionError> {
        self.send(channel_id, HostSessionEvent::Resize { cols, rows })
            .await
    }

    pub async fn close(
        &self,
        channel_id: Uuid,
        reason: SessionCloseReason,
    ) -> Result<(), HostSessionError> {
        let sender = self
            .sessions
            .lock()
            .await
            .remove(&channel_id)
            .ok_or(HostSessionError::UnknownChannel)?;
        sender
            .send(HostSessionEvent::Close(reason))
            .await
            .map_err(|_| HostSessionError::SessionClosed)
    }

    pub async fn len(&self) -> usize {
        self.sessions.lock().await.len()
    }

    pub async fn is_empty(&self) -> bool {
        self.len().await == 0
    }

    async fn send(
        &self,
        channel_id: Uuid,
        event: HostSessionEvent,
    ) -> Result<(), HostSessionError> {
        let sender = self
            .sessions
            .lock()
            .await
            .get(&channel_id)
            .cloned()
            .ok_or(HostSessionError::UnknownChannel)?;
        sender
            .send(event)
            .await
            .map_err(|_| HostSessionError::SessionClosed)
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum HostSessionEvent {
    Input(Bytes),
    Resize { cols: u16, rows: u16 },
    Close(SessionCloseReason),
}

pub struct HostSessionHandle {
    channel_id: Uuid,
    receiver: mpsc::Receiver<HostSessionEvent>,
}

impl HostSessionHandle {
    pub fn channel_id(&self) -> Uuid {
        self.channel_id
    }

    pub async fn recv(&mut self) -> Option<HostSessionEvent> {
        self.receiver.recv().await
    }
}

impl fmt::Debug for HostSessionHandle {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("HostSessionHandle")
            .field("channel_id", &self.channel_id)
            .finish_non_exhaustive()
    }
}

pub async fn drive_session(
    factory: Arc<dyn PtyFactory>,
    launch: HerdrLaunch,
    mut session: HostSessionHandle,
    output: mpsc::Sender<Bytes>,
) -> anyhow::Result<()> {
    let pty = factory.spawn_herdr(launch).await?;
    loop {
        tokio::select! {
            event = session.recv() => {
                match event {
                    Some(HostSessionEvent::Input(bytes)) => pty.write_input(&bytes).await?,
                    Some(HostSessionEvent::Resize { cols, rows }) => pty.resize(cols, rows).await?,
                    Some(HostSessionEvent::Close(_)) | None => {
                        pty.close().await?;
                        return Ok(());
                    }
                }
            }
            bytes = pty.read_output(PTY_READ_MAXIMUM) => {
                let bytes = bytes?;
                if bytes.is_empty() {
                    pty.close().await?;
                    return Ok(());
                }
                if output.send(bytes).await.is_err() {
                    pty.close().await?;
                    return Ok(());
                }
            }
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, Error, PartialEq)]
pub enum HostSessionError {
    #[error("channel already exists")]
    DuplicateChannel,
    #[error("Host session limit reached")]
    LimitExceeded,
    #[error("channel is unknown")]
    UnknownChannel,
    #[error("channel receiver is closed")]
    SessionClosed,
}
