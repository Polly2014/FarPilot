use std::fs::{self, OpenOptions};
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};

const SCHEMA_VERSION: u8 = 1;
const STALE_AFTER: Duration = Duration::from_secs(120);

#[derive(Clone, Copy, Debug, Deserialize, Serialize, Eq, PartialEq)]
#[serde(rename_all = "snake_case")]
pub enum HostRuntimeState {
    Starting,
    Connecting,
    Authenticated,
    Online,
    Backoff,
    PermanentError,
    Stopped,
}

#[derive(Clone, Copy, Debug, Deserialize, Serialize, Eq, PartialEq)]
#[serde(rename_all = "snake_case")]
pub enum ErrorCategory {
    Dns,
    Connect,
    Tls,
    Authentication,
    Protocol,
    Configuration,
    Identity,
    HerdrNotFound,
    HerdrLaunch,
    Permission,
    Io,
    Unknown,
}

impl ErrorCategory {
    pub fn classify(message: &str) -> Self {
        let message = message.to_ascii_lowercase();
        if message.contains("herdr")
            && (message.contains("not found") || message.contains("no such file"))
        {
            Self::HerdrNotFound
        } else if message.contains("herdr")
            && (message.contains("launch") || message.contains("spawn"))
        {
            Self::HerdrLaunch
        } else if message.contains("certificate")
            || message.contains("tls")
            || message.contains("ssl")
        {
            Self::Tls
        } else if message.contains("authentication")
            || message.contains("host proof")
            || message.contains("unauthorized")
        {
            Self::Authentication
        } else if message.contains("permission") || message.contains("denied") {
            Self::Permission
        } else if message.contains("dns") || message.contains("resolve") {
            Self::Dns
        } else if message.contains("protocol")
            || message.contains("frame")
            || message.contains("version")
        {
            Self::Protocol
        } else if message.contains("identity") || message.contains("dpapi") {
            Self::Identity
        } else if message.contains("config") || message.contains("invalid gateway") {
            Self::Configuration
        } else if message.contains("connect")
            || message.contains("socket")
            || message.contains("websocket")
        {
            Self::Connect
        } else if message.contains("i/o") || message.contains("io error") {
            Self::Io
        } else {
            Self::Unknown
        }
    }
}

#[derive(Clone, Debug, Deserialize, Serialize, Eq, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct ManagedStatus {
    pub schema_version: u8,
    pub state: HostRuntimeState,
    pub updated_at_ms: u64,
    pub connection_generation: u64,
    pub restart_count: u32,
    pub last_error_category: Option<ErrorCategory>,
}

impl ManagedStatus {
    pub fn new(
        state: HostRuntimeState,
        connection_generation: u64,
        restart_count: u32,
        last_error_category: Option<ErrorCategory>,
    ) -> Self {
        Self::new_at(
            state,
            connection_generation,
            restart_count,
            last_error_category,
            now_ms(),
        )
    }

    pub const fn new_at(
        state: HostRuntimeState,
        connection_generation: u64,
        restart_count: u32,
        last_error_category: Option<ErrorCategory>,
        updated_at_ms: u64,
    ) -> Self {
        Self {
            schema_version: SCHEMA_VERSION,
            state,
            updated_at_ms,
            connection_generation,
            restart_count,
            last_error_category,
        }
    }

    pub fn is_stale_at(&self, now_ms: u64) -> bool {
        now_ms.saturating_sub(self.updated_at_ms) > STALE_AFTER.as_millis() as u64
    }
}

#[derive(Clone, Debug)]
pub struct StatusWriter {
    path: PathBuf,
    temporary: PathBuf,
}

impl StatusWriter {
    pub fn new(path: PathBuf) -> io::Result<Self> {
        let parent = path.parent().ok_or_else(|| {
            io::Error::new(io::ErrorKind::InvalidInput, "status path has no parent")
        })?;
        let metadata = fs::symlink_metadata(parent)?;
        if !metadata.is_dir() || metadata.file_type().is_symlink() {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "status parent must be a regular directory",
            ));
        }
        if let Ok(metadata) = fs::symlink_metadata(&path)
            && metadata.file_type().is_symlink()
        {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "status path must not be a symbolic link",
            ));
        }
        let name = path
            .file_name()
            .and_then(|name| name.to_str())
            .ok_or_else(|| {
                io::Error::new(io::ErrorKind::InvalidInput, "invalid status filename")
            })?;
        let temporary = parent.join(format!("{name}.tmp"));
        Ok(Self { path, temporary })
    }

    pub fn write<T: Serialize>(&self, status: &T) -> io::Result<()> {
        if let Ok(metadata) = fs::symlink_metadata(&self.temporary) {
            if !metadata.is_file() || metadata.file_type().is_symlink() {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidInput,
                    "unsafe temporary status path",
                ));
            }
            fs::remove_file(&self.temporary)?;
        }
        let bytes = serde_json::to_vec_pretty(status).map_err(io::Error::other)?;
        let mut output = OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&self.temporary)?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            output.set_permissions(fs::Permissions::from_mode(0o600))?;
        }
        output.write_all(&bytes)?;
        output.write_all(b"\n")?;
        output.sync_all()?;
        drop(output);
        atomic_replace(&self.temporary, &self.path)
    }
}

#[cfg(not(windows))]
fn atomic_replace(source: &Path, destination: &Path) -> io::Result<()> {
    fs::rename(source, destination)
}

#[cfg(windows)]
fn atomic_replace(source: &Path, destination: &Path) -> io::Result<()> {
    use std::os::windows::ffi::OsStrExt;

    use windows_sys::Win32::Storage::FileSystem::{
        MOVEFILE_REPLACE_EXISTING, MOVEFILE_WRITE_THROUGH, MoveFileExW,
    };

    let source = source
        .as_os_str()
        .encode_wide()
        .chain(std::iter::once(0))
        .collect::<Vec<_>>();
    let destination = destination
        .as_os_str()
        .encode_wide()
        .chain(std::iter::once(0))
        .collect::<Vec<_>>();
    let result = unsafe {
        MoveFileExW(
            source.as_ptr(),
            destination.as_ptr(),
            MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH,
        )
    };
    if result == 0 {
        Err(io::Error::last_os_error())
    } else {
        Ok(())
    }
}

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| u64::try_from(duration.as_millis()).unwrap_or(u64::MAX))
        .unwrap_or(0)
}
