//! Linux Gateway library for FarPilot.

pub mod attach;
pub mod authorized_keys;
pub mod broker;
pub mod config;
pub mod health;
pub mod host_ws;
pub mod local_attach;
pub mod pairing_http;
pub mod store;

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
