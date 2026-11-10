use std::fs;
use std::io;
use std::path::{Path, PathBuf};

use base64::Engine;
use base64::engine::general_purpose::STANDARD;
use farpilot_core::identity::HostIdentity;
use serde::{Deserialize, Serialize};
use zeroize::Zeroizing;

pub trait IdentityProtector: Send + Sync {
    fn protect(&self, plaintext: &[u8]) -> io::Result<Vec<u8>>;
    fn unprotect(&self, ciphertext: &[u8]) -> io::Result<Vec<u8>>;
}

pub struct FileIdentityStore<P> {
    path: PathBuf,
    protector: P,
}

impl<P: IdentityProtector> FileIdentityStore<P> {
    pub fn new(path: PathBuf, protector: P) -> Self {
        Self { path, protector }
    }

    pub fn load_or_create(&self) -> io::Result<HostIdentity> {
        match fs::read(&self.path) {
            Ok(bytes) => self.decode(&bytes),
            Err(error) if error.kind() == io::ErrorKind::NotFound => self.create(),
            Err(error) => Err(error),
        }
    }

    fn create(&self) -> io::Result<HostIdentity> {
        let identity = HostIdentity::generate();
        let secret = identity.to_secret_bytes();
        let protected = Zeroizing::new(self.protector.protect(&secret[..])?);
        let stored = StoredIdentity {
            version: 1,
            protected_secret_b64: STANDARD.encode(&protected[..]),
            public_key_b64: STANDARD.encode(identity.public_key().to_bytes()),
        };
        let bytes = serde_json::to_vec_pretty(&stored).map_err(invalid_data)?;
        atomic_write(&self.path, &bytes)?;
        Ok(identity)
    }

    fn decode(&self, bytes: &[u8]) -> io::Result<HostIdentity> {
        let stored: StoredIdentity = serde_json::from_slice(bytes).map_err(invalid_data)?;
        if stored.version != 1 {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "unsupported FarPilot identity version",
            ));
        }
        let protected = STANDARD
            .decode(stored.protected_secret_b64)
            .map_err(invalid_data)?;
        let plaintext = Zeroizing::new(self.protector.unprotect(&protected)?);
        let secret: [u8; 32] = plaintext.as_slice().try_into().map_err(|_| {
            io::Error::new(io::ErrorKind::InvalidData, "invalid Host secret length")
        })?;
        let identity = HostIdentity::from_secret_bytes(&secret);
        let expected = STANDARD
            .decode(stored.public_key_b64)
            .map_err(invalid_data)?;
        if expected.as_slice() != identity.public_key().to_bytes() {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "Host identity public key mismatch",
            ));
        }
        Ok(identity)
    }
}

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct StoredIdentity {
    version: u8,
    protected_secret_b64: String,
    public_key_b64: String,
}

fn atomic_write(path: &Path, bytes: &[u8]) -> io::Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    let temporary = path.with_extension("tmp");
    fs::write(&temporary, bytes)?;
    fs::rename(temporary, path)
}

fn invalid_data(error: impl std::fmt::Display) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, error.to_string())
}

#[cfg(windows)]
pub mod windows {
    use std::io;
    use std::ptr;
    use std::slice;

    use windows_sys::Win32::Foundation::LocalFree;
    use windows_sys::Win32::Security::Cryptography::{
        CRYPT_INTEGER_BLOB, CRYPTPROTECT_UI_FORBIDDEN, CryptProtectData, CryptUnprotectData,
    };

    use super::IdentityProtector;

    pub struct DpapiProtector;

    impl IdentityProtector for DpapiProtector {
        fn protect(&self, plaintext: &[u8]) -> io::Result<Vec<u8>> {
            crypt(plaintext, true)
        }

        fn unprotect(&self, ciphertext: &[u8]) -> io::Result<Vec<u8>> {
            crypt(ciphertext, false)
        }
    }

    fn crypt(input: &[u8], protect: bool) -> io::Result<Vec<u8>> {
        let mut input_blob = CRYPT_INTEGER_BLOB {
            cbData: u32::try_from(input.len()).map_err(|_| {
                io::Error::new(io::ErrorKind::InvalidInput, "identity is too large")
            })?,
            pbData: input.as_ptr().cast_mut(),
        };
        let mut output_blob = CRYPT_INTEGER_BLOB {
            cbData: 0,
            pbData: ptr::null_mut(),
        };
        let success = unsafe {
            if protect {
                CryptProtectData(
                    &mut input_blob,
                    ptr::null(),
                    ptr::null(),
                    ptr::null_mut(),
                    ptr::null(),
                    CRYPTPROTECT_UI_FORBIDDEN,
                    &mut output_blob,
                )
            } else {
                CryptUnprotectData(
                    &mut input_blob,
                    ptr::null_mut(),
                    ptr::null(),
                    ptr::null_mut(),
                    ptr::null(),
                    CRYPTPROTECT_UI_FORBIDDEN,
                    &mut output_blob,
                )
            }
        };
        if success == 0 {
            return Err(io::Error::last_os_error());
        }
        let output = unsafe {
            slice::from_raw_parts(output_blob.pbData, output_blob.cbData as usize).to_vec()
        };
        unsafe {
            LocalFree(output_blob.pbData.cast());
        }
        Ok(output)
    }
}
