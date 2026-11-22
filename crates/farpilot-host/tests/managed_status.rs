use std::time::Duration;

use farpilot_host::managed_status::{ErrorCategory, HostRuntimeState, ManagedStatus, StatusWriter};

#[test]
fn status_json_contains_only_allowlisted_fields() {
    let status = ManagedStatus::new_at(HostRuntimeState::Connecting, 7, 2, None, 1_000);
    let value = serde_json::to_value(status).unwrap();
    let mut keys = value
        .as_object()
        .unwrap()
        .keys()
        .map(String::as_str)
        .collect::<Vec<_>>();
    keys.sort_unstable();
    assert_eq!(
        keys,
        vec![
            "connection_generation",
            "last_error_category",
            "restart_count",
            "schema_version",
            "state",
            "updated_at_ms",
        ]
    );
    let text = value.to_string().to_lowercase();
    for forbidden in [
        "gateway",
        "host_id",
        "device",
        "token",
        "fingerprint",
        "ssh-ed25519",
    ] {
        assert!(!text.contains(forbidden), "leaked {forbidden}");
    }
}

#[test]
fn error_categories_are_closed_and_sanitized() {
    assert_eq!(
        ErrorCategory::classify("certificate verify failed at https://secret.example"),
        ErrorCategory::Tls
    );
    assert_eq!(
        ErrorCategory::classify("permission denied for C:\\private\\path"),
        ErrorCategory::Permission
    );
    assert_eq!(
        ErrorCategory::classify("herdr.exe was not found"),
        ErrorCategory::HerdrNotFound
    );
    assert_eq!(
        ErrorCategory::classify("unknown arbitrary detail"),
        ErrorCategory::Unknown
    );
}

#[test]
fn status_writer_atomically_replaces_a_regular_file() {
    let temp = tempfile::tempdir().unwrap();
    let path = temp.path().join("host-status.json");
    let writer = StatusWriter::new(path.clone()).unwrap();
    writer
        .write(&ManagedStatus::new_at(
            HostRuntimeState::Starting,
            1,
            0,
            None,
            1_000,
        ))
        .unwrap();
    writer
        .write(&ManagedStatus::new_at(
            HostRuntimeState::Online,
            1,
            0,
            None,
            2_000,
        ))
        .unwrap();

    let parsed: ManagedStatus = serde_json::from_slice(&std::fs::read(path).unwrap()).unwrap();
    assert_eq!(parsed.state, HostRuntimeState::Online);
    assert!(!temp.path().join("host-status.json.tmp").exists());
}

#[test]
fn status_writer_rejects_a_symlink_destination() {
    let temp = tempfile::tempdir().unwrap();
    let target = temp.path().join("real.json");
    std::fs::write(&target, b"{}").unwrap();
    let link = temp.path().join("host-status.json");
    #[cfg(unix)]
    std::os::unix::fs::symlink(&target, &link).unwrap();
    #[cfg(windows)]
    std::os::windows::fs::symlink_file(&target, &link).unwrap();

    assert!(StatusWriter::new(link).is_err());
}

#[test]
fn stale_status_is_not_reported_as_online() {
    let status = ManagedStatus::new_at(HostRuntimeState::Online, 1, 0, None, 1_000);
    assert!(status.is_stale_at(1_000 + Duration::from_secs(121).as_millis() as u64));
    assert!(!status.is_stale_at(1_000 + Duration::from_secs(120).as_millis() as u64));
}
