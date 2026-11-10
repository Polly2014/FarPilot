#![cfg(windows)]

use std::path::PathBuf;
use std::time::Duration;

use farpilot_host::herdr::HerdrConfig;
use farpilot_host::pty::{PortablePtyFactory, PtyFactory};

#[tokio::test]
async fn conpty_preserves_utf8_ansi_and_resize() {
    let factory = PortablePtyFactory;
    let config = HerdrConfig::new(PathBuf::from("powershell.exe"), None).unwrap();
    let pty = factory.spawn_herdr(config.launch(80, 24)).await.unwrap();

    // ConPTY asks the attached terminal for its cursor position before
    // PowerShell renders a prompt. A real SSH terminal answers this DSR query;
    // the fixture must emulate that part of the terminal protocol.
    let startup = tokio::time::timeout(Duration::from_secs(5), async {
        let mut output = Vec::new();
        loop {
            let chunk = pty.read_output(16 * 1024).await.unwrap();
            output.extend_from_slice(&chunk);
            if output.windows(4).any(|window| window == b"\x1b[6n") {
                break output;
            }
        }
    })
    .await
    .expect("ConPTY should request the terminal cursor position");
    assert!(startup.windows(4).any(|window| window == b"\x1b[6n"));
    pty.write_input(b"\x1b[1;1R").await.unwrap();

    pty.resize(120, 40).await.unwrap();
    pty.write_input(
        "[Console]::OutputEncoding=[System.Text.UTF8Encoding]::new(); Write-Output \"你好\"; Write-Host \"`e[31mRED`e[0m\"; exit\r\n".as_bytes(),
    )
    .await
    .unwrap();

    let result = tokio::time::timeout(Duration::from_secs(10), async {
        let mut output = Vec::new();
        loop {
            let chunk = pty.read_output(16 * 1024).await.unwrap();
            if chunk.is_empty() {
                break output;
            }
            output.extend_from_slice(&chunk);
            if output.windows(4).any(|window| window == b"\x1b[6n") {
                pty.write_input(b"\x1b[1;1R").await.unwrap();
            }
            if output
                .windows("你好".len())
                .any(|window| window == "你好".as_bytes())
                && output.windows(3).any(|window| window == b"RED")
            {
                break output;
            }
        }
    })
    .await;
    let output = result.expect("PowerShell fixture should produce output");
    assert!(
        output
            .windows("你好".len())
            .any(|window| window == "你好".as_bytes()),
        "captured output: {:?}",
        String::from_utf8_lossy(&output)
    );
    assert!(
        output.windows(3).any(|window| window == b"RED"),
        "captured output: {:?}",
        String::from_utf8_lossy(&output)
    );
    pty.close().await.unwrap();
}
