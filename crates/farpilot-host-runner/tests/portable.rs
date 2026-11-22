use std::fs;
use std::time::Duration;

use farpilot_host_runner::backoff::RestartBackoff;
use farpilot_host_runner::layout::resolve_sibling_cli;
use farpilot_host_runner::log_rotation::rotate_if_needed;
use farpilot_host_runner::status::{RunnerState, RunnerStatus};

#[test]
fn restart_backoff_is_bounded_and_resets_after_stable_online() {
    let mut backoff = RestartBackoff::default();
    let observed = (0..8).map(|_| backoff.next_delay()).collect::<Vec<_>>();
    assert_eq!(
        observed,
        vec![
            Duration::from_secs(1),
            Duration::from_secs(2),
            Duration::from_secs(4),
            Duration::from_secs(8),
            Duration::from_secs(16),
            Duration::from_secs(32),
            Duration::from_secs(60),
            Duration::from_secs(60),
        ]
    );
    backoff.observe_online(Duration::from_secs(59));
    assert_eq!(backoff.next_delay(), Duration::from_secs(60));
    backoff.observe_online(Duration::from_secs(60));
    assert_eq!(backoff.next_delay(), Duration::from_secs(1));
}

#[test]
fn sibling_cli_must_be_in_the_same_direct_release_directory() {
    let temp = tempfile::tempdir().unwrap();
    let releases = temp.path().join("releases");
    let release = releases.join("0.2.0-x86_64-pc-windows-msvc");
    fs::create_dir_all(&release).unwrap();
    let runner = release.join("farpilot-host-runner.exe");
    let cli = release.join("farpilot.exe");
    fs::write(&runner, b"runner").unwrap();
    fs::write(&cli, b"cli").unwrap();

    assert_eq!(
        resolve_sibling_cli(&runner, &releases).unwrap(),
        cli.canonicalize().unwrap()
    );
    let external = temp.path().join("external-runner.exe");
    fs::write(&external, b"runner").unwrap();
    assert!(resolve_sibling_cli(&external, &releases).is_err());
}

#[cfg(unix)]
#[test]
fn sibling_cli_rejects_a_symlink() {
    let temp = tempfile::tempdir().unwrap();
    let releases = temp.path().join("releases");
    let release = releases.join("0.2.0-x86_64-pc-windows-msvc");
    fs::create_dir_all(&release).unwrap();
    let runner = release.join("farpilot-host-runner.exe");
    let external = temp.path().join("external.exe");
    fs::write(&runner, b"runner").unwrap();
    fs::write(&external, b"external").unwrap();
    std::os::unix::fs::symlink(&external, release.join("farpilot.exe")).unwrap();

    assert!(resolve_sibling_cli(&runner, &releases).is_err());
}

#[test]
fn log_rotation_caps_active_file_and_keeps_two_generations() {
    let temp = tempfile::tempdir().unwrap();
    let log = temp.path().join("host.log");
    fs::write(&log, vec![b'a'; 11]).unwrap();
    fs::write(temp.path().join("host.log.1"), b"one").unwrap();
    fs::write(temp.path().join("host.log.2"), b"two").unwrap();

    rotate_if_needed(&log, 10).unwrap();

    assert!(!log.exists());
    assert_eq!(
        fs::read(temp.path().join("host.log.1")).unwrap(),
        vec![b'a'; 11]
    );
    assert_eq!(fs::read(temp.path().join("host.log.2")).unwrap(), b"one");
}

#[test]
fn runner_status_json_contains_only_allowlisted_fields() {
    let status = RunnerStatus::new_at(RunnerState::RunningChild, 3, Some(42), None, 1_000);
    let value = serde_json::to_value(status).unwrap();
    let mut keys = value
        .as_object()
        .unwrap()
        .keys()
        .map(String::as_str)
        .collect::<Vec<_>>();
    keys.sort_unstable();
    assert_eq!(
        keys,
        vec![
            "last_child_exit_code",
            "last_error_category",
            "next_retry_ms",
            "restart_count",
            "runner_state",
            "schema_version",
            "updated_at_ms",
        ]
    );
    let text = value.to_string().to_lowercase();
    for forbidden in ["gateway", "host_id", "device", "token", "key", "path"] {
        assert!(!text.contains(forbidden), "leaked {forbidden}");
    }
}
