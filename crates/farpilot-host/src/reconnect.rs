use std::time::Duration;

#[derive(Clone, Debug)]
pub struct ReconnectPolicy {
    initial: Duration,
    maximum: Duration,
    stable_reset: Duration,
    jitter_fraction: f64,
}

impl ReconnectPolicy {
    pub fn without_jitter(initial: Duration, maximum: Duration, stable_reset: Duration) -> Self {
        Self {
            initial,
            maximum,
            stable_reset,
            jitter_fraction: 0.0,
        }
    }

    pub fn with_jitter(
        initial: Duration,
        maximum: Duration,
        stable_reset: Duration,
        jitter_fraction: f64,
    ) -> Self {
        Self {
            initial,
            maximum,
            stable_reset,
            jitter_fraction: jitter_fraction.clamp(0.0, 0.5),
        }
    }

    pub fn delay_for_attempt(&self, attempt: u32) -> Duration {
        self.delay_for_attempt_with_sample(attempt, 0.5)
    }

    pub fn delay_for_attempt_with_sample(&self, attempt: u32, sample: f64) -> Duration {
        let multiplier = 1_u32.checked_shl(attempt.min(31)).unwrap_or(u32::MAX);
        let base = self.initial.saturating_mul(multiplier).min(self.maximum);
        let sample = sample.clamp(0.0, 1.0);
        let factor = 1.0 - self.jitter_fraction + (2.0 * self.jitter_fraction * sample);
        Duration::from_secs_f64(base.as_secs_f64() * factor).min(self.maximum)
    }

    pub async fn sleep_before_retry(&self, attempt: u32) {
        let sample = rand::random::<f64>();
        tokio::time::sleep(self.delay_for_attempt_with_sample(attempt, sample)).await;
    }

    pub fn should_reset_after(&self, authenticated_for: Duration) -> bool {
        authenticated_for >= self.stable_reset
    }
}

impl Default for ReconnectPolicy {
    fn default() -> Self {
        Self::with_jitter(
            Duration::from_secs(1),
            Duration::from_secs(120),
            Duration::from_secs(60),
            0.2,
        )
    }
}
