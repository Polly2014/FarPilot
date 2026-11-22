# FarPilot Windows Background Host Design

**Status:** Approved design; implementation not started

**Date:** 2026-11-22

## 1. Product decision

FarPilot will add a dedicated Windows user-mode supervisor named `farpilot-host-runner.exe` and distribute it together with `farpilot.exe` in one verified Windows ZIP package.

The user experience remains one installation command and one visible CLI name. The runner is an internal installer-managed component. It runs without a console window, supervises the real Host data-plane process, records sanitized local status, applies bounded restart backoff, and gives the installer one reliable lifecycle boundary for upgrade, rollback, and uninstall.

FarPilot will not use a Windows Service because Stage 0/1 installation must remain current-user scoped and elevation-free. It will not use a PowerShell/VBScript wrapper as the production supervisor because the live PowerShell-hidden experiment showed that task/process/TCP presence did not prove Gateway Host authentication.

## 2. User experience

Installation remains one command:

```powershell
irm https://farpilot.polly.wang/install.ps1 | iex
```

The installer downloads one Windows package:

```text
farpilot-windows-x86_64.zip
├── farpilot.exe
└── farpilot-host-runner.exe
```

Only `farpilot.exe` is a user-facing command. The current-user `FarPilot Host` Scheduled Task points to `farpilot-host-runner.exe run`. The task starts at logon without a visible console window.

Normal users do not download, invoke, configure, or update the runner separately.

## 3. Goals

The Windows background Host must:

1. run without administrator privileges;
2. open no inbound listener and create no firewall rule;
3. show no console window at logon or during ordinary recovery;
4. start automatically at current-user logon;
5. maintain exactly one runner instance per Windows user;
6. start exactly one managed FarPilot Host child;
7. kill the child when the runner or Scheduled Task stops;
8. restart the child after an unexpected exit with bounded exponential backoff;
9. reset backoff after a stable online interval;
10. expose sanitized local states that distinguish process existence, connection progress, authenticated Host registration, and retry/backoff;
11. retain a small bounded local log without terminal content, prompts, repository data, keys, tokens, Host IDs, device IDs, fingerprints, or full Gateway URLs;
12. let `farpilot host status` report runner/child/state/restart information;
13. migrate existing single-EXE installations without changing Host identity or configuration;
14. upgrade, roll back, retain, and uninstall the CLI and runner as one versioned unit;
15. preserve the existing fixed Herdr launcher and arbitrary-command prohibition.

## 4. Non-goals

This design does not:

- create a Windows Service;
- require administrator elevation;
- expose arbitrary PowerShell or shell execution;
- add a remote management API;
- add Web UI, notifications, multi-Host UX, file browsing, or Agent orchestration;
- resume Window B live rollback acceptance;
- publish stable/latest endpoints;
- solve Windows code signing;
- make the runner a second Agent runtime;
- let the runner edit Host identity or `host.json`;
- let the runner select arbitrary executables or command arguments.

## 5. Component boundaries

### 5.1 `farpilot.exe`

The existing CLI remains responsible for:

- Host setup and identity/config creation;
- Host pairing requests;
- Host status presentation;
- WSS authentication and reconnect behavior;
- terminal channel and ConPTY lifecycle;
- launching only the configured Herdr executable;
- device list and revocation on the Gateway.

A new internal Host execution mode accepts installer/runner-controlled paths:

```text
farpilot.exe host run-managed
  --status-file <managed absolute path>
  --event-log <managed absolute path>
```

This mode is not a general daemon interface. It rejects extra arguments and paths outside `%LOCALAPPDATA%\FarPilot\runtime`.

### 5.2 `farpilot-host-runner.exe`

The runner is a second binary in the `farpilot-cli` Cargo package or a focused workspace crate. On Windows it is compiled with the Windows GUI subsystem and therefore creates no console.

It may only:

- locate sibling `farpilot.exe` in its own canonical release directory;
- validate both files belong to the same direct release directory;
- acquire the current-user FarPilot runner mutex;
- create a Windows Job Object;
- launch `farpilot.exe host run-managed` with fixed runtime/log paths;
- assign the child to the Job Object;
- wait for child exit;
- rotate managed logs;
- apply restart backoff;
- write sanitized runner state;
- respond to normal process/task termination.

It must not:

- read or modify Host identity/config contents beyond checking required files exist;
- generate pairing tokens;
- listen on a socket or pipe;
- accept remote input;
- launch a path outside its own release directory;
- pass user-supplied arguments to the child;
- execute PowerShell, `cmd.exe`, scripts, or arbitrary binaries.

## 6. Process model

```text
Current-user Scheduled Task
        │
        └── farpilot-host-runner.exe run
                │
                ├── current-user single-instance mutex
                ├── Windows Job Object (KILL_ON_JOB_CLOSE)
                ├── status/log ownership
                └── farpilot.exe host run-managed
                        └── WSS → Gateway → Herdr sessions
```

The runner stays alive while the child runs. The Scheduled Task therefore remains `Running`, which preserves existing installer semantics for stop/update/restart.

The child is assigned to a Job Object configured with `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`. Stopping the task, terminating the runner, installer activation, rollback, or uninstall closes the Job Object and terminates the child. The installer still performs a path-scoped process cleanup as defense in depth.

## 7. Single-instance guarantee

The runner acquires a named current-user mutex before creating state or starting a child.

The mutex name is derived from a fixed FarPilot namespace plus the current Windows user SID hash. It contains no username or Host ID.

Behavior:

- first runner acquires the mutex and continues;
- a second runner exits with a dedicated already-running exit code;
- duplicate task starts do not create duplicate Host connections;
- installer tests verify one runner and one child after repeated task starts.

The runner does not treat a stale status file or PID as ownership proof. The Windows mutex is authoritative.

## 8. Child creation

The runner resolves its own executable path, canonicalizes the parent directory, and requires:

```text
<release-dir>\farpilot-host-runner.exe
<release-dir>\farpilot.exe
```

Both must be regular files in the same direct child directory of `%LOCALAPPDATA%\FarPilot\releases`.

The child is created with:

- `CREATE_NO_WINDOW`;
- no inherited stdin;
- stdout/stderr redirected to runner-owned files;
- a fixed working directory under `%LOCALAPPDATA%\FarPilot\runtime`;
- fixed arguments for `host run-managed`;
- the existing user environment required for DPAPI, native roots, networking, and Herdr path resolution;
- no elevation and no new credentials.

The runner assigns the child to the Job Object before considering startup successful. If assignment fails, it terminates the child and records a sanitized runner error.

## 9. Runtime states

The Host child writes `%LOCALAPPDATA%\FarPilot\runtime\host-status.json` atomically.

Minimum schema:

```json
{
  "schema_version": 1,
  "state": "connecting",
  "updated_at_ms": 0,
  "connection_generation": 0,
  "restart_count": 0,
  "last_error_category": null
}
```

Allowed states:

```text
starting
connecting
authenticated
online
backoff
permanent_error
stopped
```

Semantics:

- `starting`: managed child initialized and config loaded;
- `connecting`: WSS connection/authentication attempt in progress;
- `authenticated`: Gateway returned `HostReady`;
- `online`: authenticated connection entered the Host runtime loop and is eligible for broker registration/session routing;
- `backoff`: transient disconnect occurred and retry delay is active;
- `permanent_error`: configuration, identity, trust, or protocol error requires operator action;
- `stopped`: graceful managed-child shutdown completed.

The status file must never contain:

- Gateway URL or IP;
- Host ID or display name;
- device information;
- tokens, key material, fingerprints, headers, or raw protocol frames;
- Herdr command line, terminal content, prompts, repository paths, or environment values.

Writes use a sibling temporary file plus atomic replacement. The file is current-user only.

## 10. Runner state

The runner writes `%LOCALAPPDATA%\FarPilot\runtime\runner-status.json` atomically.

Minimum fields:

```json
{
  "schema_version": 1,
  "runner_state": "running_child",
  "updated_at_ms": 0,
  "restart_count": 0,
  "last_child_exit_code": null,
  "next_retry_ms": null
}
```

Allowed runner states:

```text
starting
running_child
waiting_to_restart
already_running
fatal_error
stopping
```

No process ID is required in the public status contract. Process IDs may be used internally but are not treated as identity or health.

## 11. Restart policy

Unexpected child exit uses delays:

```text
1s, 2s, 4s, 8s, 16s, 32s, 60s, 60s, ...
```

A child that remains `online` continuously for at least 60 seconds resets the restart counter.

A `permanent_error` state does not spin indefinitely. The runner records the category and uses a 5-minute retry interval so configuration can be repaired without logon/reboot, while avoiding a tight loop.

Runner-fatal errors, including invalid sibling layout, mutex initialization failure, Job Object failure, unsafe runtime paths, or status/log write failure, stop the runner and cause the task to fail visibly through Task Scheduler result codes.

## 12. Logging

Files:

```text
%LOCALAPPDATA%\FarPilot\runtime\host.log
%LOCALAPPDATA%\FarPilot\runtime\host.log.1
%LOCALAPPDATA%\FarPilot\runtime\host.log.2
```

Rules:

- each file is at most 1 MiB;
- rotate before child spawn when the active file exceeds the limit;
- retain two previous files;
- current user only;
- UTF-8 text;
- structured event name, timestamp, state, retry count, coarse duration, and sanitized error category only;
- no raw arbitrary error display if it can contain endpoint/path/header values.

Allowed error categories include:

```text
dns
connect
tls
authentication
protocol
configuration
identity
herdr_not_found
herdr_launch
io
unknown
```

The raw terminal stream is never written to these logs.

## 13. `farpilot host status`

The command continues to show static Host configuration but adds runtime information when status files exist:

```text
Runner: running_child
Host runtime: online
Restarts: 0
Last transition: <local timestamp>
Last error: none
```

If the task/runner is absent:

```text
Runner: not running
Host runtime: stale or unavailable
```

The command treats status older than a bounded threshold as stale. It does not claim online merely because a process, task, or TCP socket exists.

JSON output is added for automation:

```text
farpilot host status --json
```

The JSON uses the same sanitized schema and no private configuration values.

## 14. Installer package

Windows manifest record changes from:

```json
{"format": "exe"}
```

into:

```json
{"format": "zip"}
```

The ZIP contains exactly two root-level files with exact case-insensitive names:

```text
farpilot.exe
farpilot-host-runner.exe
```

No directory entries or other files are allowed.

### 14.1 Safe extraction

The installer rejects:

- empty archives;
- more or fewer than two entries;
- directories;
- absolute paths;
- drive-qualified paths;
- `..` or path separators in entry names;
- alternate data stream syntax;
- duplicate names under case-insensitive comparison;
- symlink/reparse entries inferred from ZIP external attributes;
- encrypted entries;
- per-entry or aggregate uncompressed-size excess;
- unexpected compression methods when the platform library cannot validate safely.

Extraction occurs into a unique staging directory under the managed root. The installer copies bytes into new regular files and never trusts archive-created filesystem metadata.

### 14.2 Binary validation

Before activation:

1. verify package SHA-256;
2. extract the exact two files;
3. verify both are regular files and not reparse points;
4. run `farpilot.exe --version`;
5. run `farpilot-host-runner.exe --version`;
6. require exact manifest version equality for both;
7. apply Authenticode policy independently to both files;
8. validate that the staged release contains exactly the two managed executables.

## 15. Versioned layout

```text
%LOCALAPPDATA%\FarPilot\
├── releases\
│   └── <version>-x86_64-pc-windows-msvc\
│       ├── farpilot.exe
│       └── farpilot-host-runner.exe
├── current -> releases\<active>
├── bin     -> releases\<active>
├── runtime\
│   ├── host-status.json
│   ├── runner-status.json
│   └── host.log*
├── install-state.json
├── host-identity.json
└── host.json
```

Runtime state is outside release directories and survives upgrades. Identity and config remain outside release directories and survive default uninstall.

## 16. Scheduled Task

The current-user task:

```text
Task: FarPilot Host
Executable: <managed-bin>\farpilot-host-runner.exe
Arguments: run
Logon type: Interactive current user
Run level: Limited
Trigger: At logon
```

The task does not invoke PowerShell, VBScript, `cmd.exe`, or a shell wrapper.

The task definition may set conservative restart-on-failure as defense in depth, but runner supervision is primary. Multiple-instance policy must not create parallel runners; the runner mutex remains authoritative.

## 17. Upgrade transaction

Before mutation, the installer captures:

- package and staged release validation;
- `current` and `bin` junction state;
- install-state metadata;
- Scheduled Task definition/running state;
- runner and child process state;
- user PATH;
- active release and retained releases;
- runtime directory existence, without reading log contents.

Activation:

1. stop Scheduled Task if present;
2. wait for runner exit and Job Object child cleanup;
3. stop only remaining managed runner/CLI processes whose canonical or alias paths are inside the FarPilot root;
4. activate the complete two-file release directory;
5. retarget `current` and `bin`;
6. update PATH and install-state;
7. register the runner task;
8. start it when the previous task or managed Host was running;
9. wait for `runner-status=running_child` and `host-status=online` within the acceptance deadline;
10. on failure restore task, junctions, PATH, install-state, prior release, and prior startup state.

A rollback must restore both executables as one unit. It must never mix a CLI from one version with a runner from another.

## 18. Uninstall

Default uninstall:

- stops the task;
- terminates runner and Job Object child;
- performs path-scoped process cleanup;
- removes task, PATH entry, junctions, releases, install-state, and runtime logs/status;
- preserves `host-identity.json`, `host.json`, and unrelated files.

`-PurgeState` additionally removes the known identity/config files after existing typed confirmation.

Legacy single-EXE installations remain uninstallable through existing install-state/task/legacy-hint rules.

## 19. Migration

The first ZIP-aware installer accepts an existing managed release containing only `farpilot.exe` as the previous version. It does not modify that historical directory.

The new ZIP is staged into a new complete two-file release directory, then atomically activated. Existing Host identity/config are reused.

The old direct-console Scheduled Task is replaced only after the new package validates. Rollback restores the previous task definition and single-EXE release.

Existing foreground Host processes launched via `releases`, `current`, or `bin` aliases are detected and stopped only during the authorized upgrade transaction.

## 20. Release workflow

Linux and macOS outputs remain single binaries.

The Windows build job:

1. builds `farpilot.exe`;
2. builds `farpilot-host-runner.exe`;
3. runs native `--version` on both;
4. runs Windows runner integration tests;
5. verifies PSScriptAnalyzer for installer scripts;
6. packages the exact two files into deterministic `farpilot-windows-x86_64.zip`;
7. uploads the ZIP as the Windows release asset.

The release manifest generator marks only the Windows target as `zip`.

Future signing order is:

```text
build both EXEs
→ sign both EXEs
→ verify Authenticode/publisher/EKU/timestamp/version
→ package exact ZIP
→ compute ZIP SHA-256
→ generate final manifest
```

## 21. Security invariants

The runner and packaging work must preserve:

- no inbound DevBox listener;
- no firewall rule;
- no arbitrary command execution;
- no shell wrapper in the final task;
- sibling executable only;
- fixed child arguments;
- private keys remain local;
- terminal bytes remain in memory and are not logged;
- status/log files contain no live identifiers or endpoints;
- task and processes are current-user and limited;
- installer paths fail closed on files, unmanaged directories, symlinks, reparse points, traversal, and external process paths;
- unknown versions/layouts/formats fail before mutation.

## 22. Failure handling

| Failure | Required result |
|---|---|
| Runner mutex already held | New runner exits; existing runner/child remain |
| Sibling CLI missing/wrong version | Runner enters fatal error; no arbitrary search path fallback |
| Job Object creation/assignment fails | Child is terminated; runner exits nonzero |
| Child transient exit | Sanitized event; bounded restart |
| Child permanent error | Sanitized category; slow retry; no busy loop |
| Status/log write fails | Runner exits nonzero rather than running unobservable |
| ZIP validation fails | No staging activation |
| One executable fails version/signature | Entire package rejected |
| Task start succeeds but Host does not reach online | Installer rolls back both executables/task/junctions |
| Rollback fails | Report both activation and rollback errors; stop cleanup |
| Uninstall task stop leaves child | Job Object and path-scoped cleanup terminate it |

## 23. Testing strategy

### 23.1 Portable Rust tests

Test:

- restart backoff and stable reset;
- state transitions and atomic JSON replacement;
- serialization contains only allowlisted fields;
- error categorization removes raw endpoint/path text;
- log rotation and size bounds;
- fixed sibling path validation;
- package version consistency logic.

### 23.2 Windows runner integration

On Windows CI:

- runner has no console window;
- one runner starts one fixture child;
- duplicate runner exits without a second child;
- child exit triggers expected backoff/restart;
- stable interval resets backoff;
- terminating runner closes Job Object and child;
- task stop removes both processes;
- runtime status/log files use expected ACL/location;
- runner rejects an external or mismatched sibling binary.

### 23.3 Windows installer RED/GREEN

Cover:

- legacy single-EXE migration to exact two-EXE ZIP;
- ZIP traversal, absolute path, extra file, duplicate case, directory, symlink/reparse, and size-limit rejection;
- both EXE version mismatch;
- both Authenticode checks;
- task points only to runner;
- upgrade stops runner/child started through release and alias paths;
- activation readiness requires fresh `online` status;
- failed readiness restores old package/task/runtime behavior;
- uninstall and purge;
- retention keeps complete two-file releases only.

### 23.4 Real DevBox acceptance

One final authorized command must prove:

1. installer consumes a reviewed two-EXE package;
2. no console window appears;
3. task, runner, and child counts are exactly one where applicable;
4. Gateway reports one logical Host;
5. Mac and Moshi enter Herdr;
6. killing only the child causes automatic restart and reconnection;
7. stopping the task removes runner and child;
8. starting the task restores online state;
9. DevBox logoff/logon restores online state;
10. logs/status are sanitized and bounded;
11. upgrade/uninstall rollback preserves Host identity/config.

## 24. Completion criteria

The feature is complete only when:

1. the Windows ZIP contains exactly the two version-matched binaries;
2. every portable and Windows integration test passes;
3. Windows installer tests pass on a real GitHub-hosted Windows runner;
4. the live DevBox shows no console window;
5. runner/child/task/status/log behavior matches this specification;
6. Gateway, Mac, and Moshi acceptance passes after logon and after child restart;
7. installer upgrade/rollback/uninstall preserve state and never mix versions;
8. tracked docs contain only sanitized evidence;
9. the former foreground-only operating-mode warning is updated only after live acceptance;
10. stable/latest/signing remain separately gated.
