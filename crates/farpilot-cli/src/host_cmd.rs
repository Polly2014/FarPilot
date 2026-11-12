#[cfg(windows)]
use std::path::PathBuf;

#[cfg(windows)]
use base64::Engine;
#[cfg(windows)]
use base64::engine::general_purpose::STANDARD;
use farpilot_host::config::{HostConfig, default_data_dir};
#[cfg(windows)]
use serde::{Deserialize, Serialize};
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
            herdr_executable: PathBuf::from("herdr.exe"),
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

pub fn status() -> anyhow::Result<()> {
    let path = default_data_dir()?.join("host.json");
    let config = HostConfig::load(&path)?;
    println!("Host: {}", config.display_name);
    println!("Host ID: {}", config.host_id);
    println!("Gateway: {}", config.gateway_https);
    println!("Herdr: {}", config.herdr_executable.display());
    Ok(())
}

pub async fn start() -> anyhow::Result<()> {
    #[cfg(not(windows))]
    {
        anyhow::bail!("host start currently requires native Windows")
    }
    #[cfg(windows)]
    {
        use std::time::Instant;

        use farpilot_host::client::{ConnectionErrorKind, HostClient, TransportSecurity};
        use farpilot_host::herdr::HerdrConfig;
        use farpilot_host::identity_store::FileIdentityStore;
        use farpilot_host::identity_store::windows::DpapiProtector;
        use farpilot_host::reconnect::ReconnectPolicy;

        let data_dir = default_data_dir()?;
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
        loop {
            let connection = client.connect_until_authenticated(&policy).await?;
            let connected_at = Instant::now();
            match connection.run_herdr(herdr.clone()).await {
                Ok(()) => eprintln!("FarPilot Gateway connection closed; reconnecting"),
                Err(error) if error.kind() == ConnectionErrorKind::Permanent => {
                    return Err(error.into());
                }
                Err(error) => eprintln!("FarPilot Gateway connection lost: {error}; reconnecting"),
            }
            if policy.should_reset_after(connected_at.elapsed()) {
                post_auth_attempt = 0;
            } else {
                post_auth_attempt = post_auth_attempt.saturating_add(1);
            }
            policy.sleep_before_retry(post_auth_attempt).await;
        }
    }
}
