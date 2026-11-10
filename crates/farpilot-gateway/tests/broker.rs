use farpilot_core::frame::{ControlFrame, SessionCloseReason, TerminalFrame};
use farpilot_core::limits::{MAX_CHANNELS_PER_HOST, MAX_PENDING_BYTES_PER_CHANNEL};
use farpilot_gateway::broker::{AttachEvent, BrokerError, HostCommand, SessionBroker};
use farpilot_gateway::store::GatewayStore;

async fn authorized_broker() -> (
    SessionBroker,
    farpilot_gateway::store::HostRecord,
    farpilot_gateway::store::DeviceRecord,
) {
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
    (SessionBroker::new(store), host, device)
}

#[tokio::test]
async fn authorized_channel_routes_control_and_terminal_frames() {
    let (broker, host, device) = authorized_broker().await;
    let mut registered = broker.register_host(&host.id).await;
    let mut attach = broker.open(&device.id, &host.id, 120, 40).await.unwrap();

    let HostCommand::Control(ControlFrame::SessionOpen {
        channel_id,
        device_id,
        cols,
        rows,
    }) = registered.recv().await.unwrap()
    else {
        panic!("expected SessionOpen");
    };
    assert_eq!(channel_id, attach.channel_id());
    assert_eq!(device_id, device.id);
    assert_eq!((cols, rows), (120, 40));

    registered
        .send_control(ControlFrame::SessionOpened { channel_id })
        .await
        .unwrap();
    assert_eq!(attach.recv().await, Some(AttachEvent::Opened));

    attach.send_terminal(b"input").await.unwrap();
    let HostCommand::Terminal(frame) = registered.recv().await.unwrap() else {
        panic!("expected terminal input");
    };
    assert_eq!(&frame.payload[..], b"input");

    registered
        .send_terminal(TerminalFrame {
            channel_id,
            payload: b"output".as_slice().into(),
        })
        .await
        .unwrap();
    assert_eq!(
        attach.recv().await,
        Some(AttachEvent::Terminal(b"output".as_slice().into()))
    );
}

#[tokio::test]
async fn unauthorized_or_offline_hosts_are_refused() {
    let (broker, host, _device) = authorized_broker().await;
    let stranger = "device_stranger";

    assert_eq!(
        broker.open(stranger, &host.id, 80, 24).await.unwrap_err(),
        BrokerError::Unauthorized
    );

    let store = GatewayStore::connect("sqlite::memory:").await.unwrap();
    let offline_host = store.enroll_host("Offline", b"offline-key").await.unwrap();
    let offline_device = store
        .add_device("Device", "ssh-ed25519 OFFLINE")
        .await
        .unwrap();
    store
        .grant_device(&offline_device.id, &offline_host.id)
        .await
        .unwrap();
    let offline_broker = SessionBroker::new(store);
    assert_eq!(
        offline_broker
            .open(&offline_device.id, &offline_host.id, 80, 24)
            .await
            .unwrap_err(),
        BrokerError::HostOffline
    );
}

#[tokio::test]
async fn host_channel_limit_is_enforced_with_unique_ids() {
    let (broker, host, device) = authorized_broker().await;
    let _registered = broker.register_host(&host.id).await;
    let mut ids = std::collections::HashSet::new();
    let mut handles = Vec::new();

    for _ in 0..MAX_CHANNELS_PER_HOST {
        let handle = broker.open(&device.id, &host.id, 80, 24).await.unwrap();
        assert!(ids.insert(handle.channel_id()));
        handles.push(handle);
    }
    assert_eq!(
        broker.open(&device.id, &host.id, 80, 24).await.unwrap_err(),
        BrokerError::LimitExceeded
    );
    drop(handles);
}

#[tokio::test]
async fn host_disconnect_marks_offline_and_closes_channels() {
    let (broker, host, device) = authorized_broker().await;
    let registered = broker.register_host(&host.id).await;
    let mut attach = broker.open(&device.id, &host.id, 80, 24).await.unwrap();

    registered.disconnect().await;

    assert!(!broker.is_host_online(&host.id).await);
    assert_eq!(
        attach.recv().await,
        Some(AttachEvent::Closed(SessionCloseReason::HostDisconnected))
    );
}

#[tokio::test]
async fn disconnect_and_replacement_close_old_channels_without_replay() {
    let (broker, host, device) = authorized_broker().await;
    let first = broker.register_host(&host.id).await;
    let mut attach = broker.open(&device.id, &host.id, 80, 24).await.unwrap();
    let channel_id = attach.channel_id();

    let mut replacement = broker.register_host(&host.id).await;
    assert_eq!(
        attach.recv().await,
        Some(AttachEvent::Closed(SessionCloseReason::HostDisconnected))
    );
    assert!(replacement.try_recv().is_err());
    assert_eq!(
        broker
            .route_host_control(
                &host.id,
                replacement.generation(),
                ControlFrame::SessionOpened { channel_id }
            )
            .await,
        Err(BrokerError::UnknownChannel)
    );
    drop(first);
}

#[tokio::test]
async fn slow_client_closes_only_its_channel() {
    let (broker, host, device) = authorized_broker().await;
    let mut registered = broker.register_host(&host.id).await;
    let mut attach = broker.open(&device.id, &host.id, 80, 24).await.unwrap();
    let channel_id = attach.channel_id();
    let _ = registered.recv().await;

    let chunk = vec![b'x'; MAX_PENDING_BYTES_PER_CHANNEL / 4];
    for _ in 0..4 {
        registered
            .send_terminal(TerminalFrame {
                channel_id,
                payload: chunk.clone().into(),
            })
            .await
            .unwrap();
    }
    assert_eq!(
        registered
            .send_terminal(TerminalFrame {
                channel_id,
                payload: vec![b'y'; 1].into(),
            })
            .await,
        Err(BrokerError::SlowConsumer)
    );
    assert!(broker.is_host_online(&host.id).await);

    for _ in 0..4 {
        assert!(matches!(
            attach.recv().await,
            Some(AttachEvent::Terminal(_))
        ));
    }
    assert_eq!(
        attach.recv().await,
        Some(AttachEvent::Closed(SessionCloseReason::SlowConsumer))
    );
}
