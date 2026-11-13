use std::io::{Read, Write};
use std::sync::{Arc, Mutex};

use async_trait::async_trait;
use bytes::Bytes;
use portable_pty::{CommandBuilder, MasterPty, PtySize, native_pty_system};

use crate::herdr::HerdrLaunch;

#[async_trait]
pub trait PtySession: Send + Sync {
    async fn write_input(&self, bytes: &[u8]) -> anyhow::Result<()>;
    async fn read_output(&self, maximum: usize) -> anyhow::Result<Bytes>;
    async fn resize(&self, cols: u16, rows: u16) -> anyhow::Result<()>;
    async fn close(&self) -> anyhow::Result<()>;
}

#[async_trait]
pub trait PtyFactory: Send + Sync {
    async fn spawn_herdr(&self, request: HerdrLaunch) -> anyhow::Result<Arc<dyn PtySession>>;
}

#[derive(Default)]
pub struct PortablePtyFactory;

#[async_trait]
impl PtyFactory for PortablePtyFactory {
    async fn spawn_herdr(&self, request: HerdrLaunch) -> anyhow::Result<Arc<dyn PtySession>> {
        tokio::task::spawn_blocking(move || spawn_portable(request)).await?
    }
}

struct PortablePtySession {
    master: Arc<Mutex<Box<dyn MasterPty + Send>>>,
    reader: Arc<Mutex<Box<dyn Read + Send>>>,
    writer: Arc<Mutex<Option<Box<dyn Write + Send>>>>,
    child: Arc<Mutex<Box<dyn portable_pty::Child + Send + Sync>>>,
}

#[async_trait]
impl PtySession for PortablePtySession {
    async fn write_input(&self, bytes: &[u8]) -> anyhow::Result<()> {
        let writer = self.writer.clone();
        let bytes = bytes.to_vec();
        tokio::task::spawn_blocking(move || {
            let mut writer = writer
                .lock()
                .map_err(|_| anyhow::anyhow!("PTY writer poisoned"))?;
            let writer = writer
                .as_mut()
                .ok_or_else(|| anyhow::anyhow!("PTY is closed"))?;
            writer.write_all(&bytes)?;
            writer.flush()?;
            Ok(())
        })
        .await?
    }

    async fn read_output(&self, maximum: usize) -> anyhow::Result<Bytes> {
        let reader = self.reader.clone();
        tokio::task::spawn_blocking(move || {
            let mut buffer = vec![0_u8; maximum.max(1)];
            let count = reader
                .lock()
                .map_err(|_| anyhow::anyhow!("PTY reader poisoned"))?
                .read(&mut buffer)?;
            buffer.truncate(count);
            Ok(Bytes::from(buffer))
        })
        .await?
    }

    async fn resize(&self, cols: u16, rows: u16) -> anyhow::Result<()> {
        let master = self.master.clone();
        tokio::task::spawn_blocking(move || {
            master
                .lock()
                .map_err(|_| anyhow::anyhow!("PTY master poisoned"))?
                .resize(PtySize {
                    rows,
                    cols,
                    pixel_width: 0,
                    pixel_height: 0,
                })
        })
        .await?
    }

    async fn close(&self) -> anyhow::Result<()> {
        let writer = self.writer.clone();
        let child = self.child.clone();
        tokio::task::spawn_blocking(move || {
            let kill_result = child
                .lock()
                .map_err(|_| anyhow::anyhow!("PTY child poisoned"))?
                .kill();
            writer
                .lock()
                .map_err(|_| anyhow::anyhow!("PTY writer poisoned"))?
                .take();
            kill_result?;
            Ok(())
        })
        .await?
    }
}

fn spawn_portable(request: HerdrLaunch) -> anyhow::Result<Arc<dyn PtySession>> {
    let pty_system = native_pty_system();
    let pair = pty_system.openpty(PtySize {
        rows: request.rows(),
        cols: request.cols(),
        pixel_width: 0,
        pixel_height: 0,
    })?;
    let reader = pair.master.try_clone_reader()?;
    let writer = pair.master.take_writer()?;
    let mut command = CommandBuilder::new(request.executable());
    if let Some(session) = request.session() {
        command.args(["--session", session]);
    }
    let child = pair.slave.spawn_command(command)?;
    drop(pair.slave);

    Ok(Arc::new(PortablePtySession {
        master: Arc::new(Mutex::new(pair.master)),
        reader: Arc::new(Mutex::new(reader)),
        writer: Arc::new(Mutex::new(Some(writer))),
        child: Arc::new(Mutex::new(child)),
    }))
}
