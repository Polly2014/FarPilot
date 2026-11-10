use farpilot_core::pairing::PairingToken;
use farpilot_gateway::store::{AuditEvent, GatewayStore, StoreError};
use std::time::{Duration, SystemTime};

async fn memory_store() -> GatewayStore {
    GatewayStore::connect("sqlite::memory:")
        .await
        .expect("in-memory Gateway store should initialize")
}

#[tokio::test]
async fn device_grants_are_revocable() {
    let store = memory_store().await;
    let host = store
        .enroll_host("Company DevBox", b"host-public-key")
        .await
        .unwrap();
    let device = store
        .add_device("Baoli MacBook", "ssh-ed25519 AAAATEST mac")
        .await
        .unwrap();

    store.grant_device(&device.id, &host.id).await.unwrap();
    assert!(store.device_can_access(&device.id, &host.id).await.unwrap());

    store.revoke_device(&device.id).await.unwrap();
    assert!(!store.device_can_access(&device.id, &host.id).await.unwrap());
}

#[tokio::test]
async fn revoked_device_cannot_be_regranted() {
    let store = memory_store().await;
    let host = store
        .enroll_host("Company DevBox", b"host-public-key")
        .await
        .unwrap();
    let device = store
        .add_device("Lost Phone", "ssh-ed25519 AAAALOST lost")
        .await
        .unwrap();
    store.revoke_device(&device.id).await.unwrap();

    assert_eq!(
        store.grant_device(&device.id, &host.id).await,
        Err(StoreError::DeviceRevoked)
    );
    assert!(!store.device_can_access(&device.id, &host.id).await.unwrap());
}

#[tokio::test]
async fn pairing_consumption_atomically_adds_device_grant_and_audit() {
    let store = memory_store().await;
    let host = store
        .enroll_host("Company DevBox", b"host-public-key")
        .await
        .unwrap();
    let now = SystemTime::UNIX_EPOCH + Duration::from_secs(1_000);
    let token = PairingToken::generate(&host.id, now, Duration::from_secs(300));
    store.insert_pairing_token(token.record()).await.unwrap();

    let device = store
        .consume_pairing_token_and_add_device(
            token.secret(),
            "Baoli iPhone",
            "ssh-ed25519 AAAAPHONE phone",
            now,
        )
        .await
        .unwrap();

    assert!(store.device_can_access(&device.id, &host.id).await.unwrap());
    let audits = store.list_audit_events().await.unwrap();
    assert!(audits.iter().any(|event| {
        event.action == "device.paired"
            && event.outcome == "success"
            && event.actor_id.as_deref() == Some(device.id.as_str())
            && event.target_id.as_deref() == Some(host.id.as_str())
    }));
    assert_eq!(
        store
            .consume_pairing_token_and_add_device(
                token.secret(),
                "Replay",
                "ssh-ed25519 AAAAREPLAY replay",
                now,
            )
            .await,
        Err(StoreError::InvalidPairingToken)
    );
}

#[tokio::test]
async fn pairing_token_can_only_win_one_concurrent_claim() {
    let store = memory_store().await;
    let host = store
        .enroll_host("Company DevBox", b"host-public-key")
        .await
        .unwrap();
    let now = SystemTime::UNIX_EPOCH + Duration::from_secs(1_000);
    let token = PairingToken::generate(&host.id, now, Duration::from_secs(300));
    store.insert_pairing_token(token.record()).await.unwrap();

    let first_store = store.clone();
    let second_store = store.clone();
    let secret = token.secret().to_owned();
    let first_secret = secret.clone();
    let first = tokio::spawn(async move {
        first_store
            .consume_pairing_token_and_add_device(
                &first_secret,
                "First",
                "ssh-ed25519 AAAAFIRST first",
                now,
            )
            .await
    });
    let second = tokio::spawn(async move {
        second_store
            .consume_pairing_token_and_add_device(
                &secret,
                "Second",
                "ssh-ed25519 AAAASECOND second",
                now,
            )
            .await
    });

    let results = [first.await.unwrap(), second.await.unwrap()];
    assert_eq!(results.iter().filter(|result| result.is_ok()).count(), 1);
    assert_eq!(
        results
            .iter()
            .filter(|result| matches!(result, Err(StoreError::InvalidPairingToken)))
            .count(),
        1
    );
}

#[tokio::test]
async fn audit_schema_has_no_payload_field() {
    let store = memory_store().await;
    store
        .append_audit(AuditEvent {
            actor_type: "operator".into(),
            actor_id: Some("operator_1".into()),
            action: "gateway.started".into(),
            target_type: None,
            target_id: None,
            outcome: "success".into(),
            bytes_in: 0,
            bytes_out: 0,
        })
        .await
        .unwrap();

    let columns = store.audit_column_names().await.unwrap();
    assert!(!columns.iter().any(|column| {
        matches!(
            column.as_str(),
            "payload" | "terminal_data" | "prompt" | "token_secret"
        )
    }));
}
