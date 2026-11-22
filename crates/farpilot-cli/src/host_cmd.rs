#[cfg(any(windows, test))]
use std::ffi::OsString;
#[cfg(any(windows, test))]
use std::io;
use std::path::PathBuf;

#[cfg(windows)]
use base64::Engine;
#[cfg(windows)]
use base64::engine::general_purpose::STANDARD;
use farpilot_host::config::{HostConfig, default_data_dir};
use farpilot_host::managed_status::{ErrorCategory, ManagedStatus};
#[cfg(windows)]
use farpilot_host::managed_status::{HostRuntimeState, StatusWriter};
#[cfg(windows)]
use serde::Deserialize;
use serde::Serialize;
use url::Url;

#[cfg(windows)]
use crate::qr;

#[cfg(windows)]
#[derive(Serialize)]
struct EnrollRequest<'a> {
    enrollment_token: &'a str,
    display_name: &'a str,
    public_key_b64: String,
}

#[cfg(windows)]
#[derive(Deserialize)]
struct EnrollResponse {
    host_id: String,
    display_name: String,
}

#[cfg(any(windows, test))]
fn resolve_executable_on_path(name: &str, path: Option<OsString>) -> io::Result<PathBuf> {
    let requested = PathBuf::from(name);
    if requested.is_absolute() {
        return requested.canonicalize().and_then(|path| {
            path.is_file().then_some(path).ok_or_else(|| {
                io::Error::new(io::ErrorKind::NotFound, format!("{name} is not a file"))
            })
        });
    }
    let path = path.ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::NotFound,
            format!("PATH is not set; cannot locate {name}"),
        )
    })?;
    for directory in std::env::split_paths(&path) {
        let candidate = directory.join(&requested);
        if candidate.is_file() {
            return candidate.canonicalize();
        }
    }
    Err(io::Error::new(
        io::ErrorKind::NotFound,
        format!("{name} was not found on PATH"),
    ))
}

pub async fn setup(gateway: Url, enrollment_code: &str, name: &str) -> anyhow::Result<()> {
    #[cfg(not(windows))]
    {
        let _ = (gateway, enrollment_code, name);
        anyhow::bail!("host setup currently requires native Windows")
    }
    #[cfg(windows)]
    {
        use farpilot_host::client::{HostClient, TransportSecurity};
        use farpilot_host::identity_store::FileIdentityStore;
        use farpilot_host::identity_store::windows::DpapiProtector;

        let data_dir = default_data_dir()?;
        let identity_path = data_dir.join("host-identity.json");
        let config_path = data_dir.join("host.json");
        let identity_store = FileIdentityStore::new(identity_path, DpapiProtector);
        let identity = identity_store.load_or_create()?;
        let enrollment_url = gateway.join("v1/hosts/enroll")?;
        let response = reqwest::Client::new()
            .post(enrollment_url)
            .json(&EnrollRequest {
                enrollment_token: enrollment_code,
                display_name: name,
                public_key_b64: STANDARD.encode(identity.public_key().to_bytes()),
            })
            .send()
            .await?;
        if !response.status().is_success() {
            anyhow::bail!(
                "Gateway enrollment failed with status {}",
                response.status()
            );
        }
        let enrolled: EnrollResponse = response.json().await?;
        let config = HostConfig {
            version: 1,
            gateway_https: gateway,
            host_id: enrolled.host_id.clone(),
            display_name: enrolled.display_name,
            herdr_executable: resolve_executable_on_path("herdr.exe", std::env::var_os("PATH"))?,
            herdr_session: Some("default".into()),
        };
        config.save(&config_path)?;

        let secret = identity.to_secret_bytes();
        let client_identity = farpilot_core::identity::HostIdentity::from_secret_bytes(&secret);
        let mut connection = HostClient::new(
            config.gateway_wss()?.as_str(),
            config.host_id,
            client_identity,
            TransportSecurity::RequireTls,
        )?
        .connect_once()
        .await?;
        let invitation = connection.create_pairing().await?;
        println!("Pairing URL: {}", invitation.pairing_url);
        println!("Expires at: {}", invitation.expires_at_ms);
        println!("{}", qr::render(&invitation.pairing_url)?);
        connection.close().await?;
        Ok(())
    }
}

pub async fn pair() -> anyhow::Result<()> {
    #[cfg(not(windows))]
    {
        anyhow::bail!("host pair currently requires native Windows")
    }
    #[cfg(windows)]
    {
        use farpilot_host::client::{HostClient, TransportSecurity};
        use farpilot_host::identity_store::FileIdentityStore;
        use farpilot_host::identity_store::windows::DpapiProtector;

        let data_dir = default_data_dir()?;
        let config = HostConfig::load(&data_dir.join("host.json"))?;
        let identity = FileIdentityStore::new(data_dir.join("host-identity.json"), DpapiProtector)
            .load_or_create()?;
        let mut connection = HostClient::new(
            config.gateway_wss()?.as_str(),
            config.host_id,
            identity,
            TransportSecurity::RequireTls,
        )?
        .connect_once()
        .await?;
        let invitation = connection.create_pairing().await?;
        println!("Pairing URL: {}", invitation.pairing_url);
        println!("Expires at: {}", invitation.expires_at_ms);
        println!("{}", qr::render(&invitation.pairing_url)?);
        connection.close().await?;
        Ok(())
    }
}

#[derive(Serialize)]
struct SanitizedRuntimeStatus {
    runner_state: String,
    host_state: String,
    restart_count: u32,
    last_error_category: Option<ErrorCategory>,
    updated_at_ms: u64,
}

fn load_sanitized_runtime_status(data_dir: &std::path::Path) -> SanitizedRuntimeStatus {
    let runtime = data_dir.join("runtime");
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|duration| u64::try_from(duration.as_millis()).unwrap_or(u64::MAX))
        .unwrap_or(0);
    let host = std::fs::read(runtime.join("host-status.json"))
        .ok()
        .and_then(|bytes| serde_json::from_slice::<ManagedStatus>(&bytes).ok());
    let runner = std::fs::read(runtime.join("runner-status.json"))
        .ok()
        .and_then(|bytes| serde_json::from_slice::<serde_json::Value>(&bytes).ok());
    let runner_state = runner
        .as_ref()
        .and_then(|value| value.get("runner_state"))
        .and_then(serde_json::Value::as_str)
        .unwrap_or("not_running")
        .to_owned();
    let (host_state, restart_count, last_error_category, updated_at_ms) = match host {
        Some(status) if status.is_stale_at(now) => (
            "stale".to_owned(),
            status.restart_count,
            status.last_error_category,
            status.updated_at_ms,
        ),
        Some(status) => (
            serde_json::to_value(status.state)
                .ok()
                .and_then(|value| value.as_str().map(str::to_owned))
                .unwrap_or_else(|| "unavailable".to_owned()),
            status.restart_count,
            status.last_error_category,
            status.updated_at_ms,
        ),
        None => ("unavailable".to_owned(), 0, None, 0),
    };
    SanitizedRuntimeStatus {
        runner_state,
        host_state,
        restart_count,
        last_error_category,
        updated_at_ms,
    }
}

pub fn status(json: bool) -> anyhow::Result<()> {
    let data_dir = default_data_dir()?;
    let runtime = load_sanitized_runtime_status(&data_dir);
    if json {
        println!("{}", serde_json::to_string(&runtime)?);
        return Ok(());
    }
    let config = HostConfig::load(&data_dir.join("host.json"))?;
    println!("Host: {}", config.display_name);
    println!("Host ID: {}", config.host_id);
    println!("Gateway: {}", config.gateway_https);
    println!("Herdr: {}", config.herdr_executable.display());
    println!("Runner: {}", runtime.runner_state);
    println!("Host runtime: {}", runtime.host_state);
    println!("Restarts: {}", runtime.restart_count);
    println!(
        "Last error: {}",
        runtime
            .last_error_category
            .map(|category| format!("{category:?}").to_ascii_lowercase())
            .unwrap_or_else(|| "none".to_owned())
    );
    Ok(())
}

pub async fn start() -> anyhow::Result<()> {
    #[cfg(not(windows))]
    {
        anyhow::bail!("host start currently requires native Windows")
    }
    #[cfg(windows)]
    start_windows(None).await
}

pub async fn run_managed(status_file: PathBuf, event_log: PathBuf) -> anyhow::Result<()> {
    #[cfg(not(windows))]
    {
        let _ = (status_file, event_log);
        anyhow::bail!("managed Host runtime requires native Windows")
    }
    #[cfg(windows)]
    {
        let data_dir = default_data_dir()?;
        let runtime = data_dir.join("runtime");
        std::fs::create_dir_all(&runtime)?;
        let metadata = std::fs::symlink_metadata(&runtime)?;
        if !metadata.is_dir() || metadata.file_type().is_symlink() {
            anyhow::bail!("FarPilot runtime path is unsafe")
        }
        let expected_status = runtime.join("host-status.json");
        let expected_log = runtime.join("host.log");
        if status_file != expected_status || event_log != expected_log {
            anyhow::bail!("managed Host paths must use the FarPilot runtime directory")
        }
        let writer = StatusWriter::new(status_file)?;
        start_windows(Some(writer)).await
    }
}

#[cfg(windows)]
async fn start_windows(status_writer: Option<StatusWriter>) -> anyhow::Result<()> {
    use std::time::Instant;

    use farpilot_host::client::{ConnectionErrorKind, HostClient, TransportSecurity};
    use farpilot_host::herdr::HerdrConfig;
    use farpilot_host::identity_store::FileIdentityStore;
    use farpilot_host::identity_store::windows::DpapiProtector;
    use farpilot_host::reconnect::ReconnectPolicy;

    let data_dir = default_data_dir()?;
    if let Some(writer) = &status_writer {
        writer.write(&ManagedStatus::new(HostRuntimeState::Starting, 0, 0, None))?;
    }
    let config = HostConfig::load(&data_dir.join("host.json"))?;
    let identity = FileIdentityStore::new(data_dir.join("host-identity.json"), DpapiProtector)
        .load_or_create()?;
    let client = HostClient::new(
        config.gateway_wss()?.as_str(),
        config.host_id.clone(),
        identity,
        TransportSecurity::RequireTls,
    )?;
    let policy = ReconnectPolicy::default();
    let herdr = HerdrConfig::new(config.herdr_executable, config.herdr_session)?;
    let mut post_auth_attempt: u32 = 0;
    let mut generation: u64 = 0;
    loop {
        generation = generation.saturating_add(1);
        if let Some(writer) = &status_writer {
            writer.write(&ManagedStatus::new(
                HostRuntimeState::Connecting,
                generation,
                post_auth_attempt,
                None,
            ))?;
        }
        let connection = match client.connect_until_authenticated(&policy).await {
            Ok(connection) => connection,
            Err(error) => {
                let category = ErrorCategory::classify(&error.to_string());
                if let Some(writer) = &status_writer {
                    writer.write(&ManagedStatus::new(
                        HostRuntimeState::PermanentError,
                        generation,
                        post_auth_attempt,
                        Some(category),
                    ))?;
                }
                return Err(error.into());
            }
        };
        if let Some(writer) = &status_writer {
            writer.write(&ManagedStatus::new(
                HostRuntimeState::Authenticated,
                generation,
                post_auth_attempt,
                None,
            ))?;
            writer.write(&ManagedStatus::new(
                HostRuntimeState::Online,
                generation,
                post_auth_attempt,
                None,
            ))?;
        }
        let connected_at = Instant::now();
        let failure = match connection.run_herdr(herdr.clone()).await {
            Ok(()) => {
                eprintln!("FarPilot Gateway connection closed; reconnecting");
                None
            }
            Err(error) if error.kind() == ConnectionErrorKind::Permanent => {
                let category = ErrorCategory::classify(&error.to_string());
                if let Some(writer) = &status_writer {
                    writer.write(&ManagedStatus::new(
                        HostRuntimeState::PermanentError,
                        generation,
                        post_auth_attempt,
                        Some(category),
                    ))?;
                }
                return Err(error.into());
            }
            Err(error) => {
                eprintln!("FarPilot Gateway connection lost: {error}; reconnecting");
                Some(ErrorCategory::classify(&error.to_string()))
            }
        };
        if policy.should_reset_after(connected_at.elapsed()) {
            post_auth_attempt = 0;
        } else {
            post_auth_attempt = post_auth_attempt.saturating_add(1);
        }
        if let Some(writer) = &status_writer {
            writer.write(&ManagedStatus::new(
                HostRuntimeState::Backoff,
                generation,
                post_auth_attempt,
                failure,
            ))?;
        }
        policy.sleep_before_retry(post_auth_attempt).await;
    }
}

#[cfg(test)]
mod tests {
    use std::ffi::OsString;
    use std::fs;
    use std::time::{SystemTime, UNIX_EPOCH};

    #[test]
    fn resolves_herdr_to_an_absolute_path_from_path() {
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let root = std::env::temp_dir().join(format!(
            "farpilot-herdr-path-{}-{nonce}",
            std::process::id()
        ));
        fs::create_dir_all(&root).unwrap();
        let executable = root.join("herdr.exe");
        fs::write(&executable, b"fixture").unwrap();
        let path = std::env::join_paths([&root]).unwrap();

        let resolved = super::resolve_executable_on_path("herdr.exe", Some(path)).unwrap();

        assert!(resolved.is_absolute());
        assert_eq!(resolved, executable.canonicalize().unwrap());
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn missing_herdr_is_rejected_before_config_is_saved() {
        let error = super::resolve_executable_on_path(
            "herdr.exe",
            Some(OsString::from("definitely-missing-directory")),
        )
        .unwrap_err();

        assert_eq!(error.kind(), std::io::ErrorKind::NotFound);
        assert!(error.to_string().contains("herdr.exe"));
    }
}
