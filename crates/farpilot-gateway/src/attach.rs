use std::sync::Arc;

use async_trait::async_trait;
use bytes::Bytes;
use farpilot_core::frame::{SessionCloseReason, SessionRefusalReason};
use thiserror::Error;

use crate::broker::{AttachEvent, BrokerError, SessionBroker};
use crate::store::HostRecord;

#[async_trait]
pub trait AttachIo: Send + Sync {
    async fn read_input(&self) -> anyhow::Result<Option<Bytes>>;
    async fn write_output(&self, bytes: &[u8]) -> anyhow::Result<()>;
    async fn next_resize(&self) -> anyhow::Result<Option<(u16, u16)>>;
}

#[derive(Clone)]
pub struct AttachService {
    broker: SessionBroker,
}

impl AttachService {
    pub fn new(broker: SessionBroker) -> Self {
        Self { broker }
    }

    pub async fn attach_device(
        &self,
        device_id: &str,
        io: Arc<dyn AttachIo>,
        cols: u16,
        rows: u16,
    ) -> Result<(), AttachError> {
        let hosts = self.broker.available_hosts_for_device(device_id).await?;
        let host = select_host(&hosts, io.as_ref()).await?;
        let mut handle = self.broker.open(device_id, &host.id, cols, rows).await?;

        loop {
            tokio::select! {
                input = io.read_input() => {
                    match input? {
                        Some(bytes) => handle.send_terminal(&bytes).await?,
                        None => {
                            let _ = handle.close(SessionCloseReason::ClientClosed).await;
                            return Ok(());
                        }
                    }
                }
                resize = io.next_resize() => {
                    if let Some((cols, rows)) = resize? {
                        handle.resize(cols, rows).await?;
                    }
                }
                event = handle.recv() => {
                    match event {
                        Some(AttachEvent::Opened) => {}
                        Some(AttachEvent::Terminal(bytes)) => io.write_output(&bytes).await?,
                        Some(AttachEvent::Refused(reason)) => return Err(AttachError::Refused(reason)),
                        Some(AttachEvent::Closed(_)) | None => return Ok(()),
                    }
                }
            }
        }
    }
}

async fn select_host(hosts: &[HostRecord], io: &dyn AttachIo) -> Result<HostRecord, AttachError> {
    match hosts {
        [] => Err(AttachError::NoOnlineHost),
        [host] => Ok(host.clone()),
        hosts => {
            let mut menu = String::from("FarPilot hosts:\r\n");
            for (index, host) in hosts.iter().enumerate() {
                menu.push_str(&format!("  {}. {}\r\n", index + 1, host.display_name));
            }
            menu.push_str("Select host: ");
            io.write_output(menu.as_bytes()).await?;
            let selection = io
                .read_input()
                .await?
                .ok_or(AttachError::InvalidSelection)?;
            let selection = std::str::from_utf8(&selection)
                .map_err(|_| AttachError::InvalidSelection)?
                .trim()
                .parse::<usize>()
                .map_err(|_| AttachError::InvalidSelection)?;
            hosts
                .get(selection.saturating_sub(1))
                .cloned()
                .ok_or(AttachError::InvalidSelection)
        }
    }
}

#[derive(Debug, Error)]
pub enum AttachError {
    #[error("no authorized Host is online")]
    NoOnlineHost,
    #[error("Host selection is invalid")]
    InvalidSelection,
    #[error("Host refused the session: {0:?}")]
    Refused(SessionRefusalReason),
    #[error("terminal I/O failed")]
    Io(#[from] anyhow::Error),
    #[error("session broker failed")]
    Broker(#[from] BrokerError),
}
