use std::time::Duration;

const MAXIMUM_DELAY: Duration = Duration::from_secs(60);
const STABLE_ONLINE: Duration = Duration::from_secs(60);

#[derive(Clone, Debug, Default)]
pub struct RestartBackoff {
    attempt: u32,
}

impl RestartBackoff {
    pub fn next_delay(&mut self) -> Duration {
        let multiplier = 1_u64.checked_shl(self.attempt.min(31)).unwrap_or(u64::MAX);
        self.attempt = self.attempt.saturating_add(1);
        Duration::from_secs(multiplier).min(MAXIMUM_DELAY)
    }

    pub fn observe_online(&mut self, duration: Duration) {
        if duration >= STABLE_ONLINE {
            self.attempt = 0;
        }
    }

    pub const fn restart_count(&self) -> u32 {
        self.attempt
    }
}
