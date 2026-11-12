use std::path::PathBuf;

use farpilot_gateway::authorized_keys::{AuthorizedDeviceKey, write_authorized_keys};
use farpilot_gateway::store::GatewayStore;

pub async fn list() -> anyhow::Result<()> {
    let store = open_store().await?;
    for device in store.list_active_devices().await? {
        println!(
            "{}\t{}\t{}",
            device.id, device.display_name, device.fingerprint
        );
    }
    Ok(())
}

pub async fn revoke(device_id: &str, confirmed: bool) -> anyhow::Result<()> {
    validate_device_id(device_id)?;
    if !confirmed {
        anyhow::bail!("revoke requires --yes after reviewing the device ID")
    }
    let store = open_store().await?;
    store.revoke_device(device_id).await?;
    rewrite_authorized_keys(&store).await?;
    terminate_active_attach(device_id)?;
    println!("Revoked {device_id}");
    Ok(())
}

fn validate_device_id(device_id: &str) -> anyhow::Result<()> {
    let Some(suffix) = device_id.strip_prefix("device_") else {
        anyhow::bail!("invalid device ID")
    };
    if suffix.len() != 32 || !suffix.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        anyhow::bail!("invalid device ID")
    }
    Ok(())
}

#[cfg(unix)]
fn terminate_active_attach(device_id: &str) -> anyhow::Result<()> {
    let pattern = format!("/usr/local/bin/farpilot gateway attach --device-id {device_id}");
    let status = std::process::Command::new("pkill")
        .args(["-f", "--", &pattern])
        .status()?;
    if !status.success() && status.code() != Some(1) {
        anyhow::bail!("failed to terminate active device session")
    }
    Ok(())
}

#[cfg(not(unix))]
fn terminate_active_attach(_device_id: &str) -> anyhow::Result<()> {
    Ok(())
}

async fn open_store() -> anyhow::Result<GatewayStore> {
    let database_url =
        std::env::var("FARPILOT_DATABASE_URL").unwrap_or_else(|_| "sqlite://farpilot.db".into());
    Ok(GatewayStore::connect(&database_url).await?)
}

async fn rewrite_authorized_keys(store: &GatewayStore) -> anyhow::Result<()> {
    let path = std::env::var_os("FARPILOT_AUTHORIZED_KEYS")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/var/lib/farpilot/authorized_keys"));
    let keys = store
        .list_active_devices()
        .await?
        .into_iter()
        .map(|device| AuthorizedDeviceKey {
            device_id: device.id,
            ssh_public_key: device.ssh_public_key,
        })
        .collect::<Vec<_>>();
    write_authorized_keys(&path, &keys)?;
    Ok(())
}
