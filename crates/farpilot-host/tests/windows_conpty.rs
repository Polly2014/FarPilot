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

    pty.resize(120, 40).await.unwrap();
    pty.write_input(
        "[Console]::OutputEncoding=[System.Text.UTF8Encoding]::new(); Write-Output \"你好\"; Write-Host \"`e[31mRED`e[0m\"; exit\r\n".as_bytes(),
    )
    .await
    .unwrap();

    let output = tokio::time::timeout(Duration::from_secs(10), async {
        let mut output = Vec::new();
        loop {
            let chunk = pty.read_output(16 * 1024).await.unwrap();
            if chunk.is_empty() {
                break output;
            }
            output.extend_from_slice(&chunk);
            if output
                .windows("你好".len())
                .any(|window| window == "你好".as_bytes())
                && output.windows(3).any(|window| window == b"RED")
            {
                break output;
            }
        }
    })
    .await
    .expect("PowerShell fixture should produce output");

    assert!(
        output
            .windows("你好".len())
            .any(|window| window == "你好".as_bytes())
    );
    assert!(output.windows(3).any(|window| window == b"RED"));
    pty.close().await.unwrap();
}
