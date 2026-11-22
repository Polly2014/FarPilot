use std::process::Command;

fn farpilot() -> Command {
    Command::new(env!("CARGO_BIN_EXE_farpilot"))
}

#[test]
fn planned_command_surface_is_present() {
    for args in [
        vec!["host", "setup", "--help"],
        vec!["host", "start", "--help"],
        vec!["host", "run-managed", "--help"],
        vec!["host", "pair", "--help"],
        vec!["host", "status", "--help"],
        vec!["gateway", "serve", "--help"],
        vec!["gateway", "enrollment", "create", "--help"],
        vec!["gateway", "attach", "--help"],
        vec!["pair", "--help"],
        vec!["devices", "--help"],
        vec!["revoke", "--help"],
    ] {
        let output = farpilot().args(args).output().unwrap();
        assert!(
            output.status.success(),
            "{}",
            String::from_utf8_lossy(&output.stderr)
        );
    }
}

#[test]
fn host_setup_rejects_non_https_gateway_before_network_access() {
    let output = farpilot()
        .args([
            "host",
            "setup",
            "--gateway",
            "http://gateway.example.com",
            "--enrollment-code",
            "code",
            "--name",
            "Company DevBox",
        ])
        .output()
        .unwrap();

    assert!(!output.status.success());
    assert!(String::from_utf8_lossy(&output.stderr).contains("https"));
}

#[test]
fn host_status_json_is_sanitized_without_local_configuration() {
    let temporary = tempfile::tempdir().unwrap();
    let output = farpilot()
        .args(["host", "status", "--json"])
        .env("LOCALAPPDATA", temporary.path())
        .env("XDG_DATA_HOME", temporary.path())
        .output()
        .unwrap();

    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let value: serde_json::Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(value["runner_state"], "not_running");
    assert_eq!(value["host_state"], "unavailable");
    let text = value.to_string().to_lowercase();
    for forbidden in ["gateway", "host_id", "display_name", "herdr_executable"] {
        assert!(!text.contains(forbidden), "leaked {forbidden}");
    }
}

#[test]
fn revoke_rejects_invalid_device_id_before_database_access() {
    let output = farpilot()
        .args(["revoke", "device_bad;pkill", "--yes"])
        .output()
        .unwrap();
    assert!(!output.status.success());
    assert!(String::from_utf8_lossy(&output.stderr).contains("invalid device ID"));
}

#[test]
fn unknown_flags_fail_closed() {
    let output = farpilot()
        .args(["devices", "--become-admin"])
        .output()
        .unwrap();
    assert!(!output.status.success());
}
