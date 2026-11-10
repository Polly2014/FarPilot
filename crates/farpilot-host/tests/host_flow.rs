use std::path::PathBuf;
use std::sync::{Arc, Mutex};

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
