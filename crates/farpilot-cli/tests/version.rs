use std::process::Command;

#[test]
fn version_flag_prints_package_version() {
    let output = Command::new(env!("CARGO_BIN_EXE_farpilot"))
        .arg("--version")
        .output()
        .expect("farpilot binary should start");

    assert!(output.status.success());
    assert_eq!(String::from_utf8_lossy(&output.stdout), "farpilot 0.1.0\n");
    assert!(output.stderr.is_empty());
}
