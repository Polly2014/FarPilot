use std::collections::HashMap;
use std::fmt;
use std::sync::Arc;

use bytes::Bytes;
use farpilot_core::frame::SessionCloseReason;
use thiserror::Error;
use tokio::sync::{Mutex, mpsc, watch};
use uuid::Uuid;

use crate::herdr::HerdrLaunch;
use crate::pty::PtyFactory;

const SESSION_EVENT_CAPACITY: usize = 64;
const SESSION_OUTPUT_CAPACITY: usize = 16;
const PTY_READ_MAXIMUM: usize = 64 * 1024;

#[derive(Clone)]
pub struct HostSessionRegistry {
    maximum: usize,
    sessions: Arc<Mutex<HashMap<Uuid, HostSessionEntry>>>,
}

struct HostSessionEntry {
    events: mpsc::Sender<HostSessionEvent>,
    close: watch::Sender<Option<SessionCloseReason>>,
    closing: bool,
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
        let (events, receiver) = mpsc::channel(SESSION_EVENT_CAPACITY);
        let (close, close_receiver) = watch::channel(None);
        sessions.insert(
            channel_id,
            HostSessionEntry {
                events,
                close,
                closing: false,
            },
        );
        Ok(HostSessionHandle {
            channel_id,
            receiver,
            close: close_receiver,
            close_delivered: false,
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
        let mut sessions = self.sessions.lock().await;
        let entry = sessions
            .get_mut(&channel_id)
            .ok_or(HostSessionError::UnknownChannel)?;
        entry.closing = true;
        let current = *entry.close.borrow();
        entry
            .close
            .send_replace(Some(upgrade_close_reason(current, reason)));
        Ok(())
    }

    pub async fn finish(&self, channel_id: Uuid) {
        self.sessions.lock().await.remove(&channel_id);
    }

    pub async fn close_all(&self, reason: SessionCloseReason) {
        let mut sessions = self.sessions.lock().await;
        for entry in sessions.values_mut() {
            entry.closing = true;
            let current = *entry.close.borrow();
            entry
                .close
                .send_replace(Some(upgrade_close_reason(current, reason)));
        }
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
        let sender = {
            let sessions = self.sessions.lock().await;
            let entry = sessions
                .get(&channel_id)
                .ok_or(HostSessionError::UnknownChannel)?;
            if entry.closing {
                return Err(HostSessionError::SessionClosed);
            }
            entry.events.clone()
        };
        sender.try_send(event).map_err(|error| match error {
            mpsc::error::TrySendError::Full(_) => HostSessionError::QueueFull,
            mpsc::error::TrySendError::Closed(_) => HostSessionError::SessionClosed,
        })
    }
}

fn upgrade_close_reason(
    current: Option<SessionCloseReason>,
    incoming: SessionCloseReason,
) -> SessionCloseReason {
    match (current, incoming) {
        (Some(existing), SessionCloseReason::ClientClosed) => existing,
        (Some(SessionCloseReason::ClientClosed), replacement) => replacement,
        (Some(existing), _) => existing,
        (None, reason) => reason,
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
    close: watch::Receiver<Option<SessionCloseReason>>,
    close_delivered: bool,
}

impl HostSessionHandle {
    pub fn channel_id(&self) -> Uuid {
        self.channel_id
    }

    pub async fn recv(&mut self) -> Option<HostSessionEvent> {
        loop {
            match self.receiver.try_recv() {
                Ok(event) => return Some(event),
                Err(mpsc::error::TryRecvError::Empty) => {}
                Err(mpsc::error::TryRecvError::Disconnected) => return self.take_close(),
            }
            if let Some(close) = self.take_close() {
                return Some(close);
            }
            tokio::select! {
                event = self.receiver.recv() => {
                    match event {
                        Some(event) => return Some(event),
                        None => return self.take_close(),
                    }
                }
                changed = self.close.changed(), if !self.close_delivered => {
                    if changed.is_err() {
                        return self.receiver.recv().await;
                    }
                    continue;
                }
            }
        }
    }

    async fn wait_for_force_close(&mut self) -> Option<SessionCloseReason> {
        if self.close_delivered {
            return None;
        }
        loop {
            let reason = *self.close.borrow_and_update();
            match reason {
                Some(SessionCloseReason::ClientClosed) => {}
                Some(reason) => {
                    self.close_delivered = true;
                    return Some(reason);
                }
                None => {}
            }
            if self.close.changed().await.is_err() {
                return None;
            }
        }
    }

    fn take_close(&mut self) -> Option<HostSessionEvent> {
        if self.close_delivered {
            return None;
        }
        let reason = *self.close.borrow_and_update();
        self.close_delivered = reason.is_some();
        reason.map(HostSessionEvent::Close)
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
    let (pty_output_tx, mut pty_output_rx) = mpsc::channel(SESSION_OUTPUT_CAPACITY);
    let reader_pty = pty.clone();
    let reader = tokio::spawn(async move {
        loop {
            let result = reader_pty.read_output(PTY_READ_MAXIMUM).await;
            let finished = result.as_ref().map_or(true, Bytes::is_empty);
            if pty_output_tx.send(result).await.is_err() || finished {
                return;
            }
        }
    });

    let result = loop {
        tokio::select! {
            event = session.recv() => {
                match event {
                    Some(HostSessionEvent::Input(bytes)) => {
                        tokio::select! {
                            result = pty.write_input(&bytes) => {
                                if let Err(error) = result {
                                    break Err(error);
                                }
                            }
                            reason = session.wait_for_force_close() => {
                                if reason.is_some() {
                                    break Ok(());
                                }
                            }
                        }
                    }
                    Some(HostSessionEvent::Resize { cols, rows }) => {
                        tokio::select! {
                            result = pty.resize(cols, rows) => {
                                if let Err(error) = result {
                                    break Err(error);
                                }
                            }
                            reason = session.wait_for_force_close() => {
                                if reason.is_some() {
                                    break Ok(());
                                }
                            }
                        }
                    }
                    Some(HostSessionEvent::Close(_)) | None => break Ok(()),
                }
            }
            result = pty_output_rx.recv() => {
                match result {
                    Some(Ok(bytes)) if bytes.is_empty() => break Ok(()),
                    Some(Ok(bytes)) => {
                        if output.send(bytes).await.is_err() {
                            break Ok(());
                        }
                    }
                    Some(Err(error)) => break Err(error),
                    None => break Ok(()),
                }
            }
        }
    };

    let close_result = pty.close().await;
    drop(pty_output_rx);
    let reader_result = reader.await;
    result?;
    close_result?;
    reader_result.map_err(|error| anyhow::anyhow!("PTY reader task failed: {error}"))?;
    Ok(())
}

#[derive(Clone, Copy, Debug, Eq, Error, PartialEq)]
pub enum HostSessionError {
    #[error("channel already exists")]
    DuplicateChannel,
    #[error("Host session limit reached")]
    LimitExceeded,
    #[error("channel is unknown")]
    UnknownChannel,
    #[error("channel event queue is full")]
    QueueFull,
    #[error("channel receiver is closed")]
    SessionClosed,
}
