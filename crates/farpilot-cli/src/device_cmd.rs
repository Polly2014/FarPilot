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
    apply_revocation_side_effects(device_id, terminate_active_attach, || {
        rewrite_authorized_keys(&store)
    })
    .await?;
    println!("Revoked {device_id}");
    Ok(())
}

async fn apply_revocation_side_effects<Terminate, Rewrite, RewriteFuture>(
    device_id: &str,
    terminate: Terminate,
    rewrite: Rewrite,
) -> anyhow::Result<()>
where
    Terminate: FnOnce(&str) -> anyhow::Result<()>,
    Rewrite: FnOnce() -> RewriteFuture,
    RewriteFuture: std::future::Future<Output = anyhow::Result<()>>,
{
    let termination_error = terminate(device_id).err();
    let rewrite_error = rewrite().await.err();
    match (termination_error, rewrite_error) {
        (None, None) => Ok(()),
        (Some(error), None) => Err(error),
        (None, Some(error)) => Err(error),
        (Some(termination), Some(rewrite)) => Err(anyhow::anyhow!(
            "active session termination failed: {termination}; authorized_keys update failed: {rewrite}"
        )),
    }
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

#[cfg(test)]
mod tests {
    use std::sync::{Arc, Mutex};

    #[tokio::test]
    async fn revocation_terminates_active_attach_before_reporting_key_sync_failure() {
        let calls = Arc::new(Mutex::new(Vec::new()));
        let terminate_calls = calls.clone();
        let rewrite_calls = calls.clone();

        let result = super::apply_revocation_side_effects(
            "device_0123456789abcdef0123456789abcdef",
            move |_| {
                terminate_calls.lock().unwrap().push("terminate");
                Ok(())
            },
            move || async move {
                rewrite_calls.lock().unwrap().push("rewrite");
                anyhow::bail!("disk full")
            },
        )
        .await;

        assert!(result.is_err());
        assert_eq!(*calls.lock().unwrap(), vec!["terminate", "rewrite"]);
    }
}
