use ed25519_dalek::{Signature, Signer, SigningKey, Verifier, VerifyingKey};
use rand::rngs::OsRng;
use thiserror::Error;
use zeroize::Zeroizing;

const HOST_PROOF_DOMAIN: &[u8] = b"farpilot-host-proof/v1";

/// A Host's long-lived Ed25519 identity.
///
/// This type intentionally implements neither `Clone` nor `Debug` so private
/// key material cannot be copied or formatted accidentally.
pub struct HostIdentity {
    signing_key: SigningKey,
}

impl HostIdentity {
    pub fn generate() -> Self {
        Self {
            signing_key: SigningKey::generate(&mut OsRng),
        }
    }

    pub fn from_secret_bytes(bytes: &[u8; 32]) -> Self {
        Self {
            signing_key: SigningKey::from_bytes(bytes),
        }
    }

    pub fn to_secret_bytes(&self) -> Zeroizing<[u8; 32]> {
        Zeroizing::new(self.signing_key.to_bytes())
    }

    pub fn public_key(&self) -> VerifyingKey {
        self.signing_key.verifying_key()
    }

    pub fn sign_challenge(&self, host_id: &str, challenge: &[u8; 32]) -> HostProof {
        let transcript = host_proof_transcript(host_id, challenge);
        HostProof(self.signing_key.sign(&transcript))
    }
}

/// Signature proving possession of a Host identity key for one challenge.
pub struct HostProof(Signature);

impl HostProof {
    pub fn verify(
        public_key: VerifyingKey,
        host_id: &str,
        challenge: &[u8; 32],
        proof: &Self,
    ) -> Result<(), HostProofError> {
        let transcript = host_proof_transcript(host_id, challenge);
        public_key
            .verify(&transcript, &proof.0)
            .map_err(|_| HostProofError::InvalidSignature)
    }

    pub fn to_bytes(&self) -> [u8; 64] {
        self.0.to_bytes()
    }

    pub fn from_bytes(bytes: &[u8; 64]) -> Self {
        Self(Signature::from_bytes(bytes))
    }
}

#[derive(Clone, Copy, Debug, Eq, Error, PartialEq)]
pub enum HostProofError {
    #[error("host proof signature is invalid")]
    InvalidSignature,
}

fn host_proof_transcript(host_id: &str, challenge: &[u8; 32]) -> Vec<u8> {
    let mut transcript = Vec::with_capacity(HOST_PROOF_DOMAIN.len() + host_id.len() + 34);
    transcript.extend_from_slice(HOST_PROOF_DOMAIN);
    transcript.push(0);
    transcript.extend_from_slice(host_id.as_bytes());
    transcript.push(0);
    transcript.extend_from_slice(challenge);
    transcript
}
