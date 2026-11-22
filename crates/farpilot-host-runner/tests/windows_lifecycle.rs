#![cfg(windows)]

use std::process::Command;

#[test]
fn runner_reports_the_workspace_version() {
    let output = Command::new(env!("CARGO_BIN_EXE_farpilot-host-runner"))
        .arg("--version")
        .output()
        .unwrap();
    assert!(output.status.success());
    assert_eq!(
        String::from_utf8(output.stdout).unwrap().trim(),
        format!("farpilot-host-runner {}", env!("CARGO_PKG_VERSION"))
    );
}

#[test]
fn runner_rejects_unknown_commands() {
    let output = Command::new(env!("CARGO_BIN_EXE_farpilot-host-runner"))
        .arg("become-admin")
        .output()
        .unwrap();
    assert!(!output.status.success());
}
