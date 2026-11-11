use std::collections::{HashMap, HashSet};
use std::fmt;
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};

use bytes::Bytes;
use farpilot_core::frame::{ControlFrame, SessionCloseReason, SessionRefusalReason, TerminalFrame};
use farpilot_core::limits::{MAX_CHANNELS_PER_HOST, MAX_PENDING_BYTES_PER_CHANNEL};
use thiserror::Error;
use tokio::sync::{Mutex, mpsc};
use uuid::Uuid;

use crate::store::GatewayStore;

const HOST_COMMAND_CAPACITY: usize = 64;
const CLIENT_EVENT_CAPACITY: usize = 8;

#[derive(Clone)]
pub struct SessionBroker {
    store: GatewayStore,
    state: Arc<Mutex<BrokerState>>,
}

#[derive(Default)]
struct BrokerState {
    hosts: HashMap<String, HostEntry>,
    channels: HashMap<Uuid, ChannelEntry>,
}

struct HostEntry {
    generation: Uuid,
    commands: mpsc::Sender<HostCommand>,
    channels: HashSet<Uuid>,
}

struct ChannelEntry {
    host_id: String,
    events: mpsc::Sender<AttachEvent>,
    pending_bytes: Arc<AtomicUsize>,
}

impl SessionBroker {
    pub fn new(store: GatewayStore) -> Self {
        Self {
            store,
            state: Arc::new(Mutex::new(BrokerState::default())),
        }
    }

    pub async fn register_host(&self, host_id: &str) -> RegisteredHost {
        let generation = Uuid::new_v4();
        let (sender, receiver) = mpsc::channel(HOST_COMMAND_CAPACITY);
        let mut state = self.state.lock().await;
        close_host_channels(&mut state, host_id, SessionCloseReason::HostDisconnected);
        state.hosts.insert(
            host_id.to_owned(),
            HostEntry {
                generation,
                commands: sender,
                channels: HashSet::new(),
            },
        );
        RegisteredHost {
            host_id: host_id.to_owned(),
            generation,
            receiver,
            broker: self.clone(),
        }
    }

    async fn disconnect_host(&self, host_id: &str, generation: Uuid) {
        let mut state = self.state.lock().await;
        if state
            .hosts
            .get(host_id)
            .is_some_and(|host| host.generation == generation)
        {
            close_host_channels(&mut state, host_id, SessionCloseReason::HostDisconnected);
            state.hosts.remove(host_id);
        }
    }

    pub async fn available_hosts_for_device(
        &self,
        device_id: &str,
    ) -> Result<Vec<crate::store::HostRecord>, BrokerError> {
        let authorized = self.store.authorized_hosts_for_device(device_id).await?;
        let state = self.state.lock().await;
        Ok(authorized
            .into_iter()
            .filter(|host| state.hosts.contains_key(&host.id))
            .collect())
    }

    pub async fn open(
        &self,
        device_id: &str,
        host_id: &str,
        cols: u16,
        rows: u16,
    ) -> Result<AttachHandle, BrokerError> {
        if !self.store.device_can_access(device_id, host_id).await? {
            return Err(BrokerError::Unauthorized);
        }

        let mut state = self.state.lock().await;
        let host = state
            .hosts
            .get_mut(host_id)
            .ok_or(BrokerError::HostOffline)?;
        if host.channels.len() >= MAX_CHANNELS_PER_HOST {
            return Err(BrokerError::LimitExceeded);
        }
        let channel_id = Uuid::new_v4();
        let (events, receiver) = mpsc::channel(CLIENT_EVENT_CAPACITY);
        let pending_bytes = Arc::new(AtomicUsize::new(0));
        host.commands
            .try_send(HostCommand::Control(ControlFrame::SessionOpen {
                channel_id,
                device_id: device_id.to_owned(),
                cols,
                rows,
            }))
            .map_err(|_| BrokerError::HostBusy)?;
        host.channels.insert(channel_id);
        state.channels.insert(
            channel_id,
            ChannelEntry {
                host_id: host_id.to_owned(),
                events,
                pending_bytes: pending_bytes.clone(),
            },
        );
        Ok(AttachHandle {
            channel_id,
            receiver,
            pending_bytes,
            broker: self.clone(),
        })
    }

    pub async fn route_host_control(
        &self,
        host_id: &str,
        generation: Uuid,
        frame: ControlFrame,
    ) -> Result<(), BrokerError> {
        let channel_id = frame_channel_id(&frame).ok_or(BrokerError::InvalidHostFrame)?;
        let mut state = self.state.lock().await;
        verify_generation(&state, host_id, generation)?;
        let channel = state
            .channels
            .get(&channel_id)
            .ok_or(BrokerError::UnknownChannel)?;
        if channel.host_id != host_id {
            return Err(BrokerError::UnknownChannel);
        }
        let event = match frame {
            ControlFrame::SessionOpened { .. } => AttachEvent::Opened,
            ControlFrame::SessionRefused { reason, .. } => AttachEvent::Refused(reason),
            ControlFrame::SessionClose { reason, .. } => AttachEvent::Closed(reason),
            ControlFrame::SessionExited { .. } => {
                AttachEvent::Closed(SessionCloseReason::HostDisconnected)
            }
            _ => return Err(BrokerError::InvalidHostFrame),
        };
        channel
            .events
            .try_send(event)
            .map_err(|_| BrokerError::SlowConsumer)?;
        if matches!(
            frame,
            ControlFrame::SessionRefused { .. }
                | ControlFrame::SessionClose { .. }
                | ControlFrame::SessionExited { .. }
        ) {
            remove_channel(&mut state, channel_id);
        }
        Ok(())
    }

    pub async fn route_host_terminal(
        &self,
        host_id: &str,
        generation: Uuid,
        frame: TerminalFrame,
    ) -> Result<(), BrokerError> {
        let mut state = self.state.lock().await;
        verify_generation(&state, host_id, generation)?;
        let Some(channel) = state.channels.get(&frame.channel_id) else {
            return Err(BrokerError::UnknownChannel);
        };
        if channel.host_id != host_id {
            return Err(BrokerError::UnknownChannel);
        }
        let payload_len = frame.payload.len();
        let previous = channel
            .pending_bytes
            .fetch_add(payload_len, Ordering::AcqRel);
        if previous.saturating_add(payload_len) > MAX_PENDING_BYTES_PER_CHANNEL {
            channel
                .pending_bytes
                .fetch_sub(payload_len, Ordering::AcqRel);
            let events = channel.events.clone();
            let _ = events.try_send(AttachEvent::Closed(SessionCloseReason::SlowConsumer));
            remove_channel(&mut state, frame.channel_id);
            return Err(BrokerError::SlowConsumer);
        }
        if channel
            .events
            .try_send(AttachEvent::Terminal(frame.payload))
            .is_err()
        {
            channel
                .pending_bytes
                .fetch_sub(payload_len, Ordering::AcqRel);
            let events = channel.events.clone();
            let _ = events.try_send(AttachEvent::Closed(SessionCloseReason::SlowConsumer));
            remove_channel(&mut state, frame.channel_id);
            return Err(BrokerError::SlowConsumer);
        }
        Ok(())
    }

    pub async fn is_host_online(&self, host_id: &str) -> bool {
        self.state.lock().await.hosts.contains_key(host_id)
    }

    async fn send_client_control(
        &self,
        channel_id: Uuid,
        frame: ControlFrame,
        remove_after_send: bool,
    ) -> Result<(), BrokerError> {
        let mut state = self.state.lock().await;
        let channel = state
            .channels
            .get(&channel_id)
            .ok_or(BrokerError::UnknownChannel)?;
        let host_id = channel.host_id.clone();
        let host = state.hosts.get(&host_id).ok_or(BrokerError::HostOffline)?;
        host.commands
            .try_send(HostCommand::Control(frame))
            .map_err(|_| BrokerError::HostBusy)?;
        if remove_after_send {
            remove_channel(&mut state, channel_id);
        }
        Ok(())
    }

    async fn send_client_terminal(
        &self,
        channel_id: Uuid,
        payload: Bytes,
    ) -> Result<(), BrokerError> {
        let state = self.state.lock().await;
        let channel = state
            .channels
            .get(&channel_id)
            .ok_or(BrokerError::UnknownChannel)?;
        let host = state
            .hosts
            .get(&channel.host_id)
            .ok_or(BrokerError::HostOffline)?;
        host.commands
            .try_send(HostCommand::Terminal(TerminalFrame {
                channel_id,
                payload,
            }))
            .map_err(|_| BrokerError::HostBusy)
    }
}

pub struct RegisteredHost {
    host_id: String,
    generation: Uuid,
    receiver: mpsc::Receiver<HostCommand>,
    broker: SessionBroker,
}

impl RegisteredHost {
    pub fn generation(&self) -> Uuid {
        self.generation
    }

    pub async fn recv(&mut self) -> Option<HostCommand> {
        self.receiver.recv().await
    }

    pub fn try_recv(&mut self) -> Result<HostCommand, mpsc::error::TryRecvError> {
        self.receiver.try_recv()
    }

    pub async fn send_control(&self, frame: ControlFrame) -> Result<(), BrokerError> {
        self.broker
            .route_host_control(&self.host_id, self.generation, frame)
            .await
    }

    pub async fn send_terminal(&self, frame: TerminalFrame) -> Result<(), BrokerError> {
        self.broker
            .route_host_terminal(&self.host_id, self.generation, frame)
            .await
    }

    pub async fn disconnect(self) {
        self.broker
            .disconnect_host(&self.host_id, self.generation)
            .await;
    }
}

pub struct AttachHandle {
    channel_id: Uuid,
    receiver: mpsc::Receiver<AttachEvent>,
    pending_bytes: Arc<AtomicUsize>,
    broker: SessionBroker,
}

impl AttachHandle {
    pub fn channel_id(&self) -> Uuid {
        self.channel_id
    }

    pub async fn recv(&mut self) -> Option<AttachEvent> {
        let event = self.receiver.recv().await;
        if let Some(AttachEvent::Terminal(bytes)) = &event {
            self.pending_bytes.fetch_sub(bytes.len(), Ordering::AcqRel);
        }
        event
    }

    pub async fn send_terminal(&self, payload: &[u8]) -> Result<(), BrokerError> {
        self.broker
            .send_client_terminal(self.channel_id, Bytes::copy_from_slice(payload))
            .await
    }

    pub async fn resize(&self, cols: u16, rows: u16) -> Result<(), BrokerError> {
        self.broker
            .send_client_control(
                self.channel_id,
                ControlFrame::TerminalResize {
                    channel_id: self.channel_id,
                    cols,
                    rows,
                },
                false,
            )
            .await
    }

    pub async fn close(&self, reason: SessionCloseReason) -> Result<(), BrokerError> {
        self.broker
            .send_client_control(
                self.channel_id,
                ControlFrame::SessionClose {
                    channel_id: self.channel_id,
                    reason,
                },
                true,
            )
            .await
    }
}

impl fmt::Debug for AttachHandle {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("AttachHandle")
            .field("channel_id", &self.channel_id)
            .finish_non_exhaustive()
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum HostCommand {
    Control(ControlFrame),
    Terminal(TerminalFrame),
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum AttachEvent {
    Opened,
    Refused(SessionRefusalReason),
    Terminal(Bytes),
    Closed(SessionCloseReason),
}

#[derive(Debug, Error)]
pub enum BrokerError {
    #[error("device is not authorized for Host")]
    Unauthorized,
    #[error("Host is offline")]
    HostOffline,
    #[error("Host connection was superseded")]
    StaleHostGeneration,
    #[error("Host channel limit reached")]
    LimitExceeded,
    #[error("Host command queue is full")]
    HostBusy,
    #[error("channel is unknown")]
    UnknownChannel,
    #[error("client is consuming output too slowly")]
    SlowConsumer,
    #[error("Host sent an invalid frame for this phase")]
    InvalidHostFrame,
    #[error("Gateway store failed")]
    Store(#[from] crate::store::StoreError),
}

impl PartialEq for BrokerError {
    fn eq(&self, other: &Self) -> bool {
        std::mem::discriminant(self) == std::mem::discriminant(other)
    }
}

fn verify_generation(
    state: &BrokerState,
    host_id: &str,
    generation: Uuid,
) -> Result<(), BrokerError> {
    let host = state.hosts.get(host_id).ok_or(BrokerError::HostOffline)?;
    if host.generation != generation {
        return Err(BrokerError::StaleHostGeneration);
    }
    Ok(())
}

fn frame_channel_id(frame: &ControlFrame) -> Option<Uuid> {
    match frame {
        ControlFrame::SessionOpened { channel_id }
        | ControlFrame::SessionRefused { channel_id, .. }
        | ControlFrame::SessionClose { channel_id, .. }
        | ControlFrame::SessionExited { channel_id, .. } => Some(*channel_id),
        _ => None,
    }
}

fn close_host_channels(state: &mut BrokerState, host_id: &str, reason: SessionCloseReason) {
    let channel_ids: Vec<_> = state
        .hosts
        .get(host_id)
        .map(|host| host.channels.iter().copied().collect())
        .unwrap_or_default();
    for channel_id in channel_ids {
        if let Some(channel) = state.channels.remove(&channel_id) {
            let _ = channel.events.try_send(AttachEvent::Closed(reason));
        }
    }
}

fn remove_channel(state: &mut BrokerState, channel_id: Uuid) {
    if let Some(channel) = state.channels.remove(&channel_id)
        && let Some(host) = state.hosts.get_mut(&channel.host_id)
    {
        host.channels.remove(&channel_id);
    }
}
