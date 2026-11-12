use std::fs::{self, OpenOptions};
use std::io::{self, Write};
use std::path::Path;

use thiserror::Error;

const DEVICE_PREFIX: &str = "device_";
const DEVICE_HEX_LENGTH: usize = 32;
const FARPILOT_BINARY: &str = "/usr/local/bin/farpilot";

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AuthorizedDeviceKey {
    pub device_id: String,
    pub ssh_public_key: String,
}

pub fn render_authorized_key(key: &AuthorizedDeviceKey) -> Result<String, AuthorizedKeysError> {
    validate_device_id(&key.device_id)?;
    validate_public_key(&key.ssh_public_key)?;
    Ok(format!(
        "restrict,pty,command=\"{FARPILOT_BINARY} gateway attach --device-id {}\" {} FarPilot-{}",
        key.device_id, key.ssh_public_key, key.device_id
    ))
}

pub fn write_authorized_keys(
    path: &Path,
    keys: &[AuthorizedDeviceKey],
) -> Result<(), AuthorizedKeysError> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    let temporary = path.with_extension("tmp");
    let mut file = OpenOptions::new()
        .create(true)
        .truncate(true)
        .write(true)
        .open(&temporary)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        file.set_permissions(fs::Permissions::from_mode(0o600))?;
    }
    for key in keys {
        writeln!(file, "{}", render_authorized_key(key)?)?;
    }
    file.sync_all()?;
    fs::rename(&temporary, path)?;
    #[cfg(unix)]
    if let Some(parent) = path.parent() {
        OpenOptions::new().read(true).open(parent)?.sync_all()?;
    }
    Ok(())
}

fn validate_device_id(device_id: &str) -> Result<(), AuthorizedKeysError> {
    let Some(suffix) = device_id.strip_prefix(DEVICE_PREFIX) else {
        return Err(AuthorizedKeysError::InvalidDeviceId);
    };
    if suffix.len() != DEVICE_HEX_LENGTH || !suffix.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        return Err(AuthorizedKeysError::InvalidDeviceId);
    }
    Ok(())
}

fn validate_public_key(public_key: &str) -> Result<(), AuthorizedKeysError> {
    let mut fields = public_key.split_whitespace();
    if fields.next() != Some("ssh-ed25519")
        || fields.next().is_none()
        || fields.next().is_some()
        || public_key.chars().any(char::is_control)
    {
        return Err(AuthorizedKeysError::InvalidPublicKey);
    }
    Ok(())
}

#[derive(Debug, Error)]
pub enum AuthorizedKeysError {
    #[error("device ID is invalid")]
    InvalidDeviceId,
    #[error("SSH public key is invalid")]
    InvalidPublicKey,
    #[error("authorized_keys update failed")]
    Io(#[from] io::Error),
}

impl PartialEq for AuthorizedKeysError {
    fn eq(&self, other: &Self) -> bool {
        matches!(
            (self, other),
            (Self::InvalidDeviceId, Self::InvalidDeviceId)
                | (Self::InvalidPublicKey, Self::InvalidPublicKey)
        )
    }
}
