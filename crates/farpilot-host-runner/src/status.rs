use std::time::{SystemTime, UNIX_EPOCH};

use farpilot_host::managed_status::ErrorCategory;
use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, Debug, Deserialize, Serialize, Eq, PartialEq)]
#[serde(rename_all = "snake_case")]
pub enum RunnerState {
    Starting,
    RunningChild,
    WaitingToRestart,
    AlreadyRunning,
    FatalError,
    Stopping,
}

#[derive(Clone, Debug, Deserialize, Serialize, Eq, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct RunnerStatus {
    pub schema_version: u8,
    pub runner_state: RunnerState,
    pub updated_at_ms: u64,
    pub restart_count: u32,
    pub last_child_exit_code: Option<i32>,
    pub next_retry_ms: Option<u64>,
    pub last_error_category: Option<ErrorCategory>,
}

impl RunnerStatus {
    pub fn new(
        runner_state: RunnerState,
        restart_count: u32,
        last_child_exit_code: Option<i32>,
        next_retry_ms: Option<u64>,
    ) -> Self {
        let updated_at_ms = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|duration| u64::try_from(duration.as_millis()).unwrap_or(u64::MAX))
            .unwrap_or(0);
        Self::new_at(
            runner_state,
            restart_count,
            last_child_exit_code,
            next_retry_ms,
            updated_at_ms,
        )
    }

    pub const fn new_at(
        runner_state: RunnerState,
        restart_count: u32,
        last_child_exit_code: Option<i32>,
        next_retry_ms: Option<u64>,
        updated_at_ms: u64,
    ) -> Self {
        Self {
            schema_version: 1,
            runner_state,
            updated_at_ms,
            restart_count,
            last_child_exit_code,
            next_retry_ms,
            last_error_category: None,
        }
    }
}
