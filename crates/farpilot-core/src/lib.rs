//! Shared protocol and security primitives for FarPilot.

pub mod frame;
pub mod identity;
pub mod limits;
pub mod pairing;

/// Reports that the crate scaffold is available.
pub const fn crate_ready() -> bool {
    true
}

#[cfg(test)]
mod tests {
    #[test]
    fn crate_is_ready() {
        assert!(super::crate_ready());
    }
}
