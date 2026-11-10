use std::path::PathBuf;

use thiserror::Error;

#[derive(Clone, Debug)]
pub struct HerdrConfig {
    executable: PathBuf,
    session: Option<String>,
}

impl HerdrConfig {
    pub fn new(executable: PathBuf, session: Option<String>) -> Result<Self, HerdrConfigError> {
        if executable.as_os_str().is_empty() {
            return Err(HerdrConfigError::MissingExecutable);
        }
        if let Some(session) = &session {
            let valid = !session.is_empty()
                && session.len() <= 64
                && session
                    .bytes()
                    .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-'));
            if !valid {
                return Err(HerdrConfigError::InvalidSessionName);
            }
        }
        Ok(Self {
            executable,
            session,
        })
    }

    pub fn launch(&self, cols: u16, rows: u16) -> HerdrLaunch {
        HerdrLaunch {
            executable: self.executable.clone(),
            session: self.session.clone(),
            cols,
            rows,
        }
    }
}

#[derive(Clone, Debug)]
pub struct HerdrLaunch {
    executable: PathBuf,
    session: Option<String>,
    cols: u16,
    rows: u16,
}

impl HerdrLaunch {
    pub fn executable(&self) -> &std::path::Path {
        &self.executable
    }

    pub fn session(&self) -> Option<&str> {
        self.session.as_deref()
    }

    pub fn cols(&self) -> u16 {
        self.cols
    }

    pub fn rows(&self) -> u16 {
        self.rows
    }
}

#[derive(Clone, Copy, Debug, Eq, Error, PartialEq)]
pub enum HerdrConfigError {
    #[error("Herdr executable path is required")]
    MissingExecutable,
    #[error("Herdr session name contains unsupported characters")]
    InvalidSessionName,
}
