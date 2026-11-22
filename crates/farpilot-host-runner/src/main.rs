#![cfg_attr(windows, windows_subsystem = "windows")]

#[cfg(windows)]
mod windows;

fn main() -> anyhow::Result<()> {
    let mut arguments = std::env::args().skip(1);
    match (arguments.next().as_deref(), arguments.next()) {
        (Some("--version"), None) => {
            println!("farpilot-host-runner {}", env!("CARGO_PKG_VERSION"));
            Ok(())
        }
        (Some("run"), None) => run(),
        _ => anyhow::bail!("usage: farpilot-host-runner [--version|run]"),
    }
}

#[cfg(windows)]
fn run() -> anyhow::Result<()> {
    windows::run()
}

#[cfg(not(windows))]
fn run() -> anyhow::Result<()> {
    anyhow::bail!("FarPilot Host runner requires native Windows")
}
