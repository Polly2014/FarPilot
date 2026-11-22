use std::fs;
use std::io;
use std::path::Path;

pub fn rotate_if_needed(path: &Path, maximum_bytes: u64) -> io::Result<()> {
    let Ok(metadata) = fs::symlink_metadata(path) else {
        return Ok(());
    };
    if !metadata.is_file() || metadata.file_type().is_symlink() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "log path must be a regular file",
        ));
    }
    if metadata.len() <= maximum_bytes {
        return Ok(());
    }
    let first = suffix(path, 1)?;
    let second = suffix(path, 2)?;
    if let Ok(metadata) = fs::symlink_metadata(&second) {
        if !metadata.is_file() || metadata.file_type().is_symlink() {
            return Err(io::Error::new(io::ErrorKind::InvalidInput, "unsafe .2 log"));
        }
        fs::remove_file(&second)?;
    }
    if let Ok(metadata) = fs::symlink_metadata(&first) {
        if !metadata.is_file() || metadata.file_type().is_symlink() {
            return Err(io::Error::new(io::ErrorKind::InvalidInput, "unsafe .1 log"));
        }
        fs::rename(&first, &second)?;
    }
    fs::rename(path, first)
}

fn suffix(path: &Path, number: u8) -> io::Result<std::path::PathBuf> {
    let name = path
        .file_name()
        .and_then(|name| name.to_str())
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "invalid log name"))?;
    Ok(path.with_file_name(format!("{name}.{number}")))
}
