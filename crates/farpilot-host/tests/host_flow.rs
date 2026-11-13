use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use async_trait::async_trait;
use bytes::Bytes;
use farpilot_core::frame::SessionCloseReason;
use farpilot_host::herdr::{HerdrConfig, HerdrLaunch};
use farpilot_host::pty::{PtyFactory, PtySession};
use farpilot_host::session::{HostSessionRegistry, drive_session};
use tokio::sync::{Notify, mpsc};
use uuid::Uuid;

#[derive(Default)]
struct FakeState {
    inputs: Vec<Vec<u8>>,
    sizes: Vec<(u16, u16)>,
    closed: bool,
}

struct FakePty {
    state: Arc<Mutex<FakeState>>,
    first_output: Mutex<Option<Bytes>>,
    wake: Notify,
}

#[async_trait]
impl PtySession for FakePty {
    async fn write_input(&self, bytes: &[u8]) -> anyhow::Result<()> {
        self.state.lock().unwrap().inputs.push(bytes.to_vec());
        Ok(())
    }

    async fn read_output(&self, _maximum: usize) -> anyhow::Result<Bytes> {
        if let Some(output) = self.first_output.lock().unwrap().take() {
            return Ok(output);
        }
        self.wake.notified().await;
        Ok(Bytes::new())
    }

    async fn resize(&self, cols: u16, rows: u16) -> anyhow::Result<()> {
        self.state.lock().unwrap().sizes.push((cols, rows));
        Ok(())
    }

    async fn close(&self) -> anyhow::Result<()> {
        self.state.lock().unwrap().closed = true;
        self.wake.notify_waiters();
        Ok(())
    }
}

struct FakeFactory {
    state: Arc<Mutex<FakeState>>,
}

#[async_trait]
impl PtyFactory for FakeFactory {
    async fn spawn_herdr(&self, request: HerdrLaunch) -> anyhow::Result<Arc<dyn PtySession>> {
        assert_eq!((request.cols(), request.rows()), (80, 24));
        Ok(Arc::new(FakePty {
            state: self.state.clone(),
            first_output: Mutex::new(Some(Bytes::from_static(b"screen"))),
            wake: Notify::new(),
        }))
    }
}

struct CancellationProbePty {
    read_starts: AtomicUsize,
    read_started: Notify,
    closed: Notify,
}

#[async_trait]
impl PtySession for CancellationProbePty {
    async fn write_input(&self, _bytes: &[u8]) -> anyhow::Result<()> {
        Ok(())
    }

    async fn read_output(&self, _maximum: usize) -> anyhow::Result<Bytes> {
        self.read_starts.fetch_add(1, Ordering::SeqCst);
        self.read_started.notify_one();
        self.closed.notified().await;
        Ok(Bytes::new())
    }

    async fn resize(&self, _cols: u16, _rows: u16) -> anyhow::Result<()> {
        Ok(())
    }

    async fn close(&self) -> anyhow::Result<()> {
        self.closed.notify_waiters();
        Ok(())
    }
}

struct CancellationProbeFactory {
    pty: Arc<CancellationProbePty>,
}

#[async_trait]
impl PtyFactory for CancellationProbeFactory {
    async fn spawn_herdr(&self, _request: HerdrLaunch) -> anyhow::Result<Arc<dyn PtySession>> {
        Ok(self.pty.clone())
    }
}

struct BlockingWritePty {
    write_started: Notify,
    write_release: Notify,
    read_wake: Notify,
    closed: AtomicBool,
}

#[async_trait]
impl PtySession for BlockingWritePty {
    async fn write_input(&self, _bytes: &[u8]) -> anyhow::Result<()> {
        self.write_started.notify_one();
        self.write_release.notified().await;
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
        self.write_release.notify_waiters();
        self.read_wake.notify_waiters();
        Ok(())
    }
}

struct BlockingWriteFactory {
    pty: Arc<BlockingWritePty>,
}

#[async_trait]
impl PtyFactory for BlockingWriteFactory {
    async fn spawn_herdr(&self, _request: HerdrLaunch) -> anyhow::Result<Arc<dyn PtySession>> {
        Ok(self.pty.clone())
    }
}

#[tokio::test]
async fn disconnect_force_closes_a_pty_with_blocked_input() {
    let pty = Arc::new(BlockingWritePty {
        write_started: Notify::new(),
        write_release: Notify::new(),
        read_wake: Notify::new(),
        closed: AtomicBool::new(false),
    });
    let factory: Arc<dyn PtyFactory> = Arc::new(BlockingWriteFactory { pty: pty.clone() });
    let config = HerdrConfig::new(PathBuf::from("herdr"), None).unwrap();
    let registry = HostSessionRegistry::new(1);
    let channel_id = Uuid::new_v4();
    let handle = registry.open(channel_id).await.unwrap();
    let (output_tx, _output_rx) = mpsc::channel(4);
    let write_started = pty.write_started.notified();
    let driver = tokio::spawn(drive_session(
        factory,
        config.launch(80, 24),
        handle,
        output_tx,
    ));

    registry.input(channel_id, b"blocked").await.unwrap();
    tokio::time::timeout(Duration::from_secs(1), write_started)
        .await
        .expect("PTY write should start");
    registry
        .close(channel_id, SessionCloseReason::HostDisconnected)
        .await
        .unwrap();
    tokio::time::timeout(Duration::from_millis(100), driver)
        .await
        .expect("disconnect must force-close a blocked PTY write")
        .unwrap()
        .unwrap();
    assert!(pty.closed.load(Ordering::SeqCst));
}

#[tokio::test]
async fn client_close_escalates_to_disconnect_for_blocked_input() {
    let pty = Arc::new(BlockingWritePty {
        write_started: Notify::new(),
        write_release: Notify::new(),
        read_wake: Notify::new(),
        closed: AtomicBool::new(false),
    });
    let factory: Arc<dyn PtyFactory> = Arc::new(BlockingWriteFactory { pty: pty.clone() });
    let config = HerdrConfig::new(PathBuf::from("herdr"), None).unwrap();
    let registry = HostSessionRegistry::new(1);
    let channel_id = Uuid::new_v4();
    let handle = registry.open(channel_id).await.unwrap();
    let (output_tx, _output_rx) = mpsc::channel(4);
    let write_started = pty.write_started.notified();
    let driver = tokio::spawn(drive_session(
        factory,
        config.launch(80, 24),
        handle,
        output_tx,
    ));

    registry.input(channel_id, b"blocked").await.unwrap();
    tokio::time::timeout(Duration::from_secs(1), write_started)
        .await
        .expect("PTY write should start");
    registry
        .close(channel_id, SessionCloseReason::ClientClosed)
        .await
        .unwrap();
    registry
        .close_all(SessionCloseReason::HostDisconnected)
        .await;
    tokio::time::timeout(Duration::from_millis(100), driver)
        .await
        .expect("transport disconnect must supersede an ordered client close")
        .unwrap()
        .unwrap();
    assert!(pty.closed.load(Ordering::SeqCst));
}

#[tokio::test]
async fn session_driver_keeps_one_persistent_pty_read_while_handling_input() {
    let pty = Arc::new(CancellationProbePty {
        read_starts: AtomicUsize::new(0),
        read_started: Notify::new(),
        closed: Notify::new(),
    });
    let factory: Arc<dyn PtyFactory> = Arc::new(CancellationProbeFactory { pty: pty.clone() });
    let config = HerdrConfig::new(PathBuf::from("herdr"), None).unwrap();
    let registry = HostSessionRegistry::new(1);
    let channel_id = Uuid::new_v4();
    let handle = registry.open(channel_id).await.unwrap();
    let (output_tx, _output_rx) = mpsc::channel(4);
    let first_read = pty.read_started.notified();
    let driver = tokio::spawn(drive_session(
        factory,
        config.launch(80, 24),
        handle,
        output_tx,
    ));
    tokio::time::timeout(Duration::from_secs(1), first_read)
        .await
        .expect("PTY reader should start");

    let restarted_read = pty.read_started.notified();
    registry.input(channel_id, b"answer").await.unwrap();
    assert!(
        tokio::time::timeout(Duration::from_millis(50), restarted_read)
            .await
            .is_err(),
        "handling input must not cancel and restart the pending PTY read"
    );
    assert_eq!(pty.read_starts.load(Ordering::SeqCst), 1);

    registry
        .close(channel_id, SessionCloseReason::ClientClosed)
        .await
        .unwrap();
    driver.await.unwrap().unwrap();
}

#[tokio::test]
async fn session_driver_routes_pty_output_input_resize_and_close() {
    let state = Arc::new(Mutex::new(FakeState::default()));
    let factory: Arc<dyn PtyFactory> = Arc::new(FakeFactory {
        state: state.clone(),
    });
    let config = HerdrConfig::new(PathBuf::from("herdr"), Some("default".into())).unwrap();
    let registry = HostSessionRegistry::new(1);
    let channel_id = Uuid::new_v4();
    let handle = registry.open(channel_id).await.unwrap();
    let (output_tx, mut output_rx) = mpsc::channel(4);
    let driver = tokio::spawn(drive_session(
        factory,
        config.launch(80, 24),
        handle,
        output_tx,
    ));

    assert_eq!(output_rx.recv().await, Some(Bytes::from_static(b"screen")));
    registry.input(channel_id, b"answer").await.unwrap();
    registry.resize(channel_id, 120, 40).await.unwrap();
    registry
        .close(channel_id, SessionCloseReason::ClientClosed)
        .await
        .unwrap();
    driver.await.unwrap().unwrap();

    let state = state.lock().unwrap();
    assert_eq!(state.inputs, vec![b"answer".to_vec()]);
    assert_eq!(state.sizes, vec![(120, 40)]);
    assert!(state.closed);
}

#[test]
fn herdr_config_rejects_unsafe_session_names() {
    assert!(HerdrConfig::new(PathBuf::from("herdr"), Some("work; powershell".into())).is_err());
    assert!(HerdrConfig::new(PathBuf::from("herdr"), Some("../work".into())).is_err());
    assert!(HerdrConfig::new(PathBuf::from("herdr"), Some("work_2026-11".into())).is_ok());
}
