use std::path::Path;
use std::sync::{Arc, Mutex};

use async_trait::async_trait;
use bytes::Bytes;
use farpilot_core::frame::{ControlFrame, TerminalFrame};
use farpilot_gateway::attach::{AttachIo, AttachService};
use farpilot_gateway::authorized_keys::{
    AuthorizedDeviceKey, AuthorizedKeysError, render_authorized_key, write_authorized_keys,
};
use farpilot_gateway::broker::{HostCommand, SessionBroker};
use farpilot_gateway::local_attach::{LocalAttachFrame, read_frame, write_frame};
use farpilot_gateway::store::GatewayStore;
use tempfile::tempdir;
use tokio::sync::{Mutex as AsyncMutex, mpsc};

#[test]
fn authorized_key_is_restricted_to_one_validated_device_command() {
    let rendered = render_authorized_key(&AuthorizedDeviceKey {
        device_id: "device_0123456789abcdef0123456789abcdef".into(),
        ssh_public_key: "ssh-ed25519 AAAATEST".into(),
    })
    .unwrap();

    assert_eq!(
        rendered,
        "restrict,pty,command=\"/usr/local/bin/farpilot gateway attach --device-id device_0123456789abcdef0123456789abcdef\" ssh-ed25519 AAAATEST FarPilot-device_0123456789abcdef0123456789abcdef"
    );
    assert_eq!(
        render_authorized_key(&AuthorizedDeviceKey {
            device_id: "device_bad; touch /tmp/pwned".into(),
            ssh_public_key: "ssh-ed25519 AAAATEST".into(),
        }),
        Err(AuthorizedKeysError::InvalidDeviceId)
    );
}

#[test]
fn authorized_keys_writer_atomically_replaces_managed_file() {
    let directory = tempdir().unwrap();
    let path = directory.path().join("authorized_keys");
    std::fs::write(&path, "stale unmanaged line\n").unwrap();
    let keys = [AuthorizedDeviceKey {
        device_id: "device_0123456789abcdef0123456789abcdef".into(),
        ssh_public_key: "ssh-ed25519 AAAATEST".into(),
    }];

    write_authorized_keys(&path, &keys).unwrap();

    let contents = std::fs::read_to_string(&path).unwrap();
    assert!(!contents.contains("stale unmanaged"));
    assert_eq!(contents.lines().count(), 1);
    assert!(!Path::new(&path.with_extension("tmp")).exists());
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(
            std::fs::metadata(path).unwrap().permissions().mode() & 0o777,
            0o600
        );
    }
}

#[tokio::test]
async fn local_attach_frames_round_trip_without_losing_binary_bytes() {
    let (mut client, mut server) = tokio::io::duplex(1024);
    let writer = tokio::spawn(async move {
        write_frame(
            &mut client,
            &LocalAttachFrame::Hello {
                device_id: "device_0123456789abcdef0123456789abcdef".into(),
                cols: 80,
                rows: 24,
            },
        )
        .await
        .unwrap();
        write_frame(
            &mut client,
            &LocalAttachFrame::Input(Bytes::from_static(&[0, 1, 2, 255])),
        )
        .await
        .unwrap();
    });

    assert_eq!(
        read_frame(&mut server).await.unwrap(),
        Some(LocalAttachFrame::Hello {
            device_id: "device_0123456789abcdef0123456789abcdef".into(),
            cols: 80,
            rows: 24,
        })
    );
    assert_eq!(
        read_frame(&mut server).await.unwrap(),
        Some(LocalAttachFrame::Input(Bytes::from_static(&[0, 1, 2, 255])))
    );
    writer.await.unwrap();
}

struct FakeIo {
    input: AsyncMutex<mpsc::Receiver<Bytes>>,
    resize: AsyncMutex<mpsc::Receiver<(u16, u16)>>,
    output: Arc<Mutex<Vec<u8>>>,
}

#[async_trait]
impl AttachIo for FakeIo {
    async fn read_input(&self) -> anyhow::Result<Option<Bytes>> {
        Ok(self.input.lock().await.recv().await)
    }

    async fn write_output(&self, bytes: &[u8]) -> anyhow::Result<()> {
        self.output.lock().unwrap().extend_from_slice(bytes);
        Ok(())
    }

    async fn next_resize(&self) -> anyhow::Result<Option<(u16, u16)>> {
        Ok(self.resize.lock().await.recv().await)
    }
}

#[tokio::test]
async fn attach_bridge_forwards_terminal_bytes_and_resize() {
    let store = GatewayStore::connect("sqlite::memory:").await.unwrap();
    let host = store
        .enroll_host("Company DevBox", b"host-public-key")
        .await
        .unwrap();
    let device = store
        .add_device("Baoli MacBook", "ssh-ed25519 AAAATEST")
        .await
        .unwrap();
    store.grant_device(&device.id, &host.id).await.unwrap();
    let broker = SessionBroker::new(store);
    let mut registered = broker.register_host(&host.id).await;
    let service = AttachService::new(broker);
    let (input_tx, input_rx) = mpsc::channel(4);
    let (resize_tx, resize_rx) = mpsc::channel(4);
    let output = Arc::new(Mutex::new(Vec::new()));
    let io = Arc::new(FakeIo {
        input: AsyncMutex::new(input_rx),
        resize: AsyncMutex::new(resize_rx),
        output: output.clone(),
    });

    let attach = tokio::spawn({
        let device_id = device.id.clone();
        async move { service.attach_device(&device_id, io, 80, 24).await }
    });
    let HostCommand::Control(ControlFrame::SessionOpen { channel_id, .. }) =
        registered.recv().await.unwrap()
    else {
        panic!("expected SessionOpen");
    };
    registered
        .send_control(ControlFrame::SessionOpened { channel_id })
        .await
        .unwrap();
    input_tx.send(Bytes::from_static(b"answer")).await.unwrap();
    resize_tx.send((120, 40)).await.unwrap();

    let mut saw_input = false;
    let mut saw_resize = false;
    while !saw_input || !saw_resize {
        match registered.recv().await.unwrap() {
            HostCommand::Terminal(frame) => {
                assert_eq!(&frame.payload[..], b"answer");
                saw_input = true;
            }
            HostCommand::Control(ControlFrame::TerminalResize { cols, rows, .. }) => {
                assert_eq!((cols, rows), (120, 40));
                saw_resize = true;
            }
            other => panic!("unexpected Host command: {other:?}"),
        }
    }
    registered
        .send_terminal(TerminalFrame {
            channel_id,
            payload: Bytes::from_static(b"screen"),
        })
        .await
        .unwrap();
    registered
        .send_control(ControlFrame::SessionExited {
            channel_id,
            exit_code: Some(0),
        })
        .await
        .unwrap();

    attach.await.unwrap().unwrap();
    assert_eq!(&*output.lock().unwrap(), b"screen");
}
