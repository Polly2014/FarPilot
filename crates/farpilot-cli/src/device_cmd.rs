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
    if !confirmed {
        anyhow::bail!("revoke requires --yes after reviewing the device ID")
    }
    let store = open_store().await?;
    store.revoke_device(device_id).await?;
    rewrite_authorized_keys(&store).await?;
    println!("Revoked {device_id}");
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
