use std::collections::HashMap;
use std::time::{Duration, SystemTime};

use base64::Engine;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use rand::RngCore;
use rand::rngs::OsRng;
use sha2::{Digest, Sha256};
use thiserror::Error;
use zeroize::Zeroizing;

/// A newly issued pairing secret plus its safe-to-persist record.
///
/// The secret is zeroized on drop and intentionally has no `Debug` or `Clone`
/// implementation.
pub struct PairingToken {
    secret: Zeroizing<String>,
    record: PairingTokenRecord,
}

impl PairingToken {
    pub fn generate(host_id: impl Into<String>, now: SystemTime, lifetime: Duration) -> Self {
        let mut random = [0_u8; 32];
        OsRng.fill_bytes(&mut random);
        let secret = Zeroizing::new(URL_SAFE_NO_PAD.encode(random));
        let record = PairingTokenRecord {
            digest: digest(secret.as_bytes()),
            host_id: host_id.into(),
            created_at: now,
            expires_at: now + lifetime,
            consumed_at: None,
        };
        random.fill(0);
        Self { secret, record }
    }

    pub fn secret(&self) -> &str {
        self.secret.as_str()
    }

    pub fn record(&self) -> PairingTokenRecord {
        self.record.clone()
    }
}

/// Persistable pairing metadata that never contains the bearer secret.
#[derive(Clone)]
pub struct PairingTokenRecord {
    digest: [u8; 32],
    host_id: String,
    created_at: SystemTime,
    expires_at: SystemTime,
    consumed_at: Option<SystemTime>,
}

impl PairingTokenRecord {
    pub fn digest(&self) -> [u8; 32] {
        self.digest
    }

    pub fn host_id(&self) -> &str {
        &self.host_id
    }

    pub fn created_at(&self) -> SystemTime {
        self.created_at
    }

    pub fn expires_at(&self) -> SystemTime {
        self.expires_at
    }
}

/// Returns the digest used to look up a pairing secret without persisting it.
pub fn pairing_token_digest(secret: &str) -> [u8; 32] {
    digest(secret.as_bytes())
}

#[derive(Default)]
pub struct PairingTokenStore {
    records: HashMap<[u8; 32], PairingTokenRecord>,
}

impl PairingTokenStore {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn insert(&mut self, record: PairingTokenRecord) {
        self.records.insert(record.digest, record);
    }

    pub fn consume(&mut self, secret: &str, now: SystemTime) -> Result<PairingGrant, PairingError> {
        let record = self
            .records
            .get_mut(&digest(secret.as_bytes()))
            .ok_or(PairingError::InvalidPairingToken)?;

        if record.consumed_at.is_some() || now >= record.expires_at {
            return Err(PairingError::InvalidPairingToken);
        }

        record.consumed_at = Some(now);
        Ok(PairingGrant {
            host_id: record.host_id.clone(),
        })
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PairingGrant {
    pub host_id: String,
}

#[derive(Clone, Copy, Debug, Eq, Error, PartialEq)]
pub enum PairingError {
    #[error("pairing token is invalid")]
    InvalidPairingToken,
}

fn digest(bytes: &[u8]) -> [u8; 32] {
    Sha256::digest(bytes).into()
}
