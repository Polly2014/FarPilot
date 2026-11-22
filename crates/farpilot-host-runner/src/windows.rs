use std::ffi::OsStr;
use std::fs::{self, OpenOptions};
use std::hash::{Hash, Hasher};
use std::io;
use std::os::windows::ffi::OsStrExt;
use std::os::windows::io::AsRawHandle;
use std::os::windows::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::ptr;
use std::time::Instant;

use farpilot_host_runner::backoff::RestartBackoff;
use farpilot_host_runner::layout::resolve_sibling_cli;
use farpilot_host_runner::log_rotation::rotate_if_needed;
use windows_sys::Win32::Foundation::{CloseHandle, ERROR_ALREADY_EXISTS, GetLastError, HANDLE};
use windows_sys::Win32::System::JobObjects::{
    AssignProcessToJobObject, CreateJobObjectW, JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE,
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION, JobObjectExtendedLimitInformation,
    SetInformationJobObject,
};
use windows_sys::Win32::System::Threading::{CREATE_NO_WINDOW, CreateMutexW};

const LOG_LIMIT: u64 = 1024 * 1024;
const ALREADY_RUNNING_EXIT: i32 = 23;

struct OwnedHandle(HANDLE);

impl OwnedHandle {
    fn new(handle: HANDLE, label: &str) -> io::Result<Self> {
        if handle.is_null() {
            Err(io::Error::new(
                io::ErrorKind::Other,
                format!("{label} failed: {}", io::Error::last_os_error()),
            ))
        } else {
            Ok(Self(handle))
        }
    }
}

impl Drop for OwnedHandle {
    fn drop(&mut self) {
        unsafe {
            CloseHandle(self.0);
        }
    }
}

pub fn run() -> anyhow::Result<()> {
    let _mutex = acquire_mutex()?;
    let job = create_kill_on_close_job()?;
    let executable = std::env::current_exe()?;
    let release = executable
        .parent()
        .ok_or_else(|| anyhow::anyhow!("runner has no release directory"))?;
    let releases = release
        .parent()
        .ok_or_else(|| anyhow::anyhow!("runner release has no releases directory"))?;
    let cli = resolve_sibling_cli(&executable, releases)?;
    let runtime = runtime_dir()?;
    fs::create_dir_all(&runtime)?;
    let status = runtime.join("host-status.json");
    let log = runtime.join("host.log");
    let mut backoff = RestartBackoff::default();

    loop {
        rotate_if_needed(&log, LOG_LIMIT)?;
        let output = OpenOptions::new().create(true).append(true).open(&log)?;
        let error = output.try_clone()?;
        let started = Instant::now();
        let mut child = Command::new(&cli)
            .args([
                OsStr::new("host"),
                OsStr::new("run-managed"),
                OsStr::new("--status-file"),
                status.as_os_str(),
                OsStr::new("--event-log"),
                log.as_os_str(),
            ])
            .current_dir(&runtime)
            .stdin(Stdio::null())
            .stdout(Stdio::from(output))
            .stderr(Stdio::from(error))
            .creation_flags(CREATE_NO_WINDOW)
            .spawn()?;
        let assigned = unsafe { AssignProcessToJobObject(job.0, child.as_raw_handle() as HANDLE) };
        if assigned == 0 {
            let _ = child.kill();
            let _ = child.wait();
            return Err(io::Error::last_os_error().into());
        }
        let _status = child.wait()?;
        backoff.observe_online(started.elapsed());
        std::thread::sleep(backoff.next_delay());
    }
}

fn acquire_mutex() -> anyhow::Result<OwnedHandle> {
    let local = std::env::var_os("LOCALAPPDATA")
        .ok_or_else(|| anyhow::anyhow!("LOCALAPPDATA is not set"))?;
    let mut hasher = std::collections::hash_map::DefaultHasher::new();
    local.hash(&mut hasher);
    let name = wide(&format!(
        "Local\\FarPilotHostRunner-{:016x}",
        hasher.finish()
    ));
    let handle = OwnedHandle::new(
        unsafe { CreateMutexW(ptr::null(), 0, name.as_ptr()) },
        "CreateMutexW",
    )?;
    if unsafe { GetLastError() } == ERROR_ALREADY_EXISTS {
        std::process::exit(ALREADY_RUNNING_EXIT);
    }
    Ok(handle)
}

fn create_kill_on_close_job() -> anyhow::Result<OwnedHandle> {
    let handle = OwnedHandle::new(
        unsafe { CreateJobObjectW(ptr::null(), ptr::null()) },
        "CreateJobObjectW",
    )?;
    let mut information: JOBOBJECT_EXTENDED_LIMIT_INFORMATION = unsafe { std::mem::zeroed() };
    information.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    let result = unsafe {
        SetInformationJobObject(
            handle.0,
            JobObjectExtendedLimitInformation,
            (&raw const information).cast(),
            u32::try_from(std::mem::size_of_val(&information)).unwrap(),
        )
    };
    if result == 0 {
        return Err(io::Error::last_os_error().into());
    }
    Ok(handle)
}

fn runtime_dir() -> anyhow::Result<PathBuf> {
    let local = std::env::var_os("LOCALAPPDATA")
        .ok_or_else(|| anyhow::anyhow!("LOCALAPPDATA is not set"))?;
    Ok(Path::new(&local).join("FarPilot").join("runtime"))
}

fn wide(value: &str) -> Vec<u16> {
    OsStr::new(value)
        .encode_wide()
        .chain(std::iter::once(0))
        .collect()
}
