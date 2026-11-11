use std::fs;
use std::io;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use url::Url;

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct HostConfig {
    pub version: u8,
    pub gateway_https: Url,
    pub host_id: String,
    pub display_name: String,
    pub herdr_executable: PathBuf,
    pub herdr_session: Option<String>,
}

impl HostConfig {
    pub fn gateway_wss(&self) -> io::Result<Url> {
        let mut url = self.gateway_https.clone();
        url.set_scheme("wss")
            .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "invalid Gateway URL"))?;
        url.set_path("/ws/host");
        url.set_query(None);
        url.set_fragment(None);
        Ok(url)
    }

    pub fn load(path: &Path) -> io::Result<Self> {
        let bytes = fs::read(path)?;
        let config: Self = serde_json::from_slice(&bytes).map_err(invalid_data)?;
        if config.version != 1 || config.gateway_https.scheme() != "https" {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "unsupported or insecure FarPilot Host configuration",
            ));
        }
        Ok(config)
    }

    pub fn save(&self, path: &Path) -> io::Result<()> {
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)?;
        }
        let temporary = path.with_extension("tmp");
        fs::write(
            &temporary,
            serde_json::to_vec_pretty(self).map_err(invalid_data)?,
        )?;
        fs::rename(temporary, path)
    }
}

pub fn default_data_dir() -> io::Result<PathBuf> {
    #[cfg(windows)]
    {
        return std::env::var_os("LOCALAPPDATA")
            .map(PathBuf::from)
            .map(|path| path.join("FarPilot"))
            .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "LOCALAPPDATA is not set"));
    }
    #[cfg(not(windows))]
    {
        std::env::var_os("XDG_DATA_HOME")
            .map(PathBuf::from)
            .or_else(|| {
                std::env::var_os("HOME").map(|home| PathBuf::from(home).join(".local/share"))
            })
            .map(|path| path.join("farpilot"))
            .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "home directory is not set"))
    }
}

fn invalid_data(error: impl std::fmt::Display) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, error.to_string())
}
