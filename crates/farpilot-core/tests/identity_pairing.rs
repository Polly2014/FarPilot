use farpilot_core::identity::{HostIdentity, HostProof};
use farpilot_core::pairing::{PairingError, PairingToken, PairingTokenStore};
use std::collections::HashSet;
use std::time::{Duration, SystemTime};

#[test]
fn host_proof_binds_challenge_and_host_id() {
    let identity = HostIdentity::generate();
    let challenge = [7_u8; 32];
    let proof = identity.sign_challenge("host_123", &challenge);

    HostProof::verify(identity.public_key(), "host_123", &challenge, &proof).unwrap();
    assert!(HostProof::verify(identity.public_key(), "host_other", &challenge, &proof).is_err());

    let other_challenge = [8_u8; 32];
    assert!(
        HostProof::verify(identity.public_key(), "host_123", &other_challenge, &proof).is_err()
    );
}

#[test]
fn host_identity_round_trips_secret_bytes() {
    let identity = HostIdentity::generate();
    let secret = identity.to_secret_bytes();
    let restored = HostIdentity::from_secret_bytes(&secret);

    assert_eq!(restored.public_key(), identity.public_key());
}

#[test]
fn pairing_token_is_single_use() {
    let now = SystemTime::UNIX_EPOCH + Duration::from_secs(1_000);
    let mut store = PairingTokenStore::new();
    let token = PairingToken::generate("host_123", now, Duration::from_secs(300));
    store.insert(token.record());

    let grant = store.consume(token.secret(), now).unwrap();
    assert_eq!(grant.host_id, "host_123");
    assert_eq!(
        store.consume(token.secret(), now),
        Err(PairingError::InvalidPairingToken)
    );
}

#[test]
fn expired_and_unknown_tokens_share_the_public_error() {
    let now = SystemTime::UNIX_EPOCH + Duration::from_secs(1_000);
    let mut store = PairingTokenStore::new();
    let token = PairingToken::generate("host_123", now, Duration::from_secs(300));
    store.insert(token.record());

    assert_eq!(
        store.consume("not-a-real-token", now),
        Err(PairingError::InvalidPairingToken)
    );
    assert_eq!(
        store.consume(token.secret(), now + Duration::from_secs(300)),
        Err(PairingError::InvalidPairingToken)
    );
}

#[test]
fn generated_pairing_tokens_are_unique_and_canonical() {
    let now = SystemTime::UNIX_EPOCH + Duration::from_secs(1_000);
    let mut secrets = HashSet::new();

    for _ in 0..10_000 {
        let token = PairingToken::generate("host_123", now, Duration::from_secs(300));
        assert_eq!(token.secret().len(), 43);
        assert!(
            token
                .secret()
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-' || byte == b'_')
        );
        assert!(secrets.insert(token.secret().to_owned()));
    }
}
