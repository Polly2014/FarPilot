use std::env;
use std::time::Duration;

use thiserror::Error;

#[derive(Clone, Debug)]
pub struct GatewayConfig {
    pub public_ssh_host: String,
    pub public_ssh_port: u16,
    pub ssh_host_fingerprint: String,
    pub pairing_failure_limit: usize,
    pub pairing_failure_window: Duration,
}

impl GatewayConfig {
    pub fn from_env() -> Result<Self, ConfigError> {
        let public_ssh_host = required("FARPILOT_PUBLIC_SSH_HOST")?;
        let public_ssh_port = env::var("FARPILOT_PUBLIC_SSH_PORT")
            .unwrap_or_else(|_| "22".into())
            .parse()
            .map_err(|_| ConfigError::InvalidPort)?;
        let ssh_host_fingerprint = required("FARPILOT_SSH_HOST_FINGERPRINT")?;

        Ok(Self {
            public_ssh_host,
            public_ssh_port,
            ssh_host_fingerprint,
            pairing_failure_limit: 5,
            pairing_failure_window: Duration::from_secs(60),
        })
    }
}

#[derive(Debug, Error)]
pub enum ConfigError {
    #[error("required environment variable {0} is missing")]
    Missing(&'static str),
    #[error("FARPILOT_PUBLIC_SSH_PORT is invalid")]
    InvalidPort,
}

fn required(name: &'static str) -> Result<String, ConfigError> {
    env::var(name)
        .ok()
        .filter(|value| !value.trim().is_empty())
        .ok_or(ConfigError::Missing(name))
}
