use std::fs;
use std::io;
use std::path::{Path, PathBuf};

pub fn resolve_sibling_cli(runner: &Path, releases: &Path) -> io::Result<PathBuf> {
    reject_symlink(runner, "runner")?;
    reject_symlink(releases, "releases")?;
    let runner = runner.canonicalize()?;
    let releases = releases.canonicalize()?;
    if !runner.is_file() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "runner is not a file",
        ));
    }
    let release = runner
        .parent()
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "runner has no parent"))?;
    if release.parent() != Some(releases.as_path()) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "runner is not in a direct release directory",
        ));
    }
    let cli = release.join("farpilot.exe");
    reject_symlink(&cli, "FarPilot CLI")?;
    let cli = cli.canonicalize()?;
    if !cli.is_file() || cli.parent() != Some(release) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "FarPilot CLI is not a regular sibling file",
        ));
    }
    Ok(cli)
}

fn reject_symlink(path: &Path, label: &str) -> io::Result<()> {
    let metadata = fs::symlink_metadata(path)?;
    if metadata.file_type().is_symlink() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!("{label} must not be a symbolic link"),
        ));
    }
    Ok(())
}
