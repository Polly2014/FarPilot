//! Native Windows Host library for FarPilot.

pub mod client;
pub mod herdr;
pub mod identity_store;
pub mod pty;
pub mod reconnect;
pub mod session;

/// Reports that the crate scaffold is available.
pub const fn crate_ready() -> bool {
    farpilot_core::crate_ready()
}

#[cfg(test)]
mod tests {
    #[test]
    fn crate_is_ready() {
        assert!(super::crate_ready());
    }
}
