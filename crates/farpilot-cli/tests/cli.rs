use std::process::Command;

fn farpilot() -> Command {
    Command::new(env!("CARGO_BIN_EXE_farpilot"))
}

#[test]
fn planned_command_surface_is_present() {
    for args in [
        vec!["host", "setup", "--help"],
        vec!["host", "start", "--help"],
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
fn unknown_flags_fail_closed() {
    let output = farpilot()
        .args(["devices", "--become-admin"])
        .output()
        .unwrap();
    assert!(!output.status.success());
}
