use std::fs;
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::process::Command;

use serde::Deserialize;
use url::Url;

#[derive(Deserialize)]
struct ClaimResponse {
    device_id: String,
    host_id: String,
    ssh_host: String,
    ssh_port: u16,
    ssh_username: String,
    ssh_host_fingerprint: String,
}

pub async fn pair(code_or_url: &str) -> anyhow::Result<()> {
    let claim_url = claim_url(code_or_url)?;
    let ssh_dir = home_dir()?.join(".ssh");
    fs::create_dir_all(&ssh_dir)?;
    let key_path = ssh_dir.join("farpilot_ed25519");
    ensure_key(&key_path)?;
    let public_key = fs::read_to_string(key_path.with_extension("pub"))?;
    let device_name = std::env::var("HOSTNAME")
        .or_else(|_| std::env::var("COMPUTERNAME"))
        .unwrap_or_else(|_| "FarPilot client".into());
    let response = reqwest::Client::new()
        .post(claim_url)
        .json(&serde_json::json!({
            "device_name": device_name,
            "ssh_public_key": public_key,
        }))
        .send()
        .await?;
    if !response.status().is_success() {
        anyhow::bail!("pairing failed with status {}", response.status());
    }
    let claim: ClaimResponse = response.json().await?;
    println!("Gateway: {}:{}", claim.ssh_host, claim.ssh_port);
    println!("SSH fingerprint: {}", claim.ssh_host_fingerprint);
    print!("Write the verified FarPilot SSH profile? [y/N] ");
    io::stdout().flush()?;
    let mut answer = String::new();
    io::stdin().read_line(&mut answer)?;
    if !matches!(answer.trim(), "y" | "Y" | "yes" | "YES") {
        anyhow::bail!("pairing succeeded but SSH profile was not written")
    }
    verify_and_store_host_key(&claim, &ssh_dir)?;
    write_ssh_profile(&claim, &key_path, &ssh_dir)?;
    println!(
        "Paired device {}. Connect with: ssh farpilot-{}",
        claim.device_id, claim.host_id
    );
    Ok(())
}

fn claim_url(value: &str) -> anyhow::Result<Url> {
    if value.starts_with("https://") {
        let pairing = Url::parse(value)?;
        let secret = pairing
            .path_segments()
            .and_then(|mut segments| segments.next_back())
            .filter(|secret| !secret.is_empty())
            .ok_or_else(|| anyhow::anyhow!("pairing URL has no code"))?
            .to_owned();
        let mut claim = pairing;
        claim.set_path(&format!("/v1/pair/{secret}/claim"));
        claim.set_query(None);
        claim.set_fragment(None);
        return Ok(claim);
    }
    let base = std::env::var("FARPILOT_GATEWAY_URL")
        .map_err(|_| anyhow::anyhow!("set FARPILOT_GATEWAY_URL when using a short code"))?;
    let base = Url::parse(&base)?;
    if base.scheme() != "https" {
        anyhow::bail!("FARPILOT_GATEWAY_URL must use https")
    }
    Ok(base.join(&format!("v1/pair/{value}/claim"))?)
}

fn ensure_key(path: &Path) -> anyhow::Result<()> {
    if path.exists() && path.with_extension("pub").exists() {
        return Ok(());
    }
    let status = Command::new("ssh-keygen")
        .args(["-q", "-t", "ed25519", "-N", "", "-f"])
        .arg(path)
        .status()?;
    if !status.success() {
        anyhow::bail!("ssh-keygen failed")
    }
    Ok(())
}

fn verify_and_store_host_key(claim: &ClaimResponse, ssh_dir: &Path) -> anyhow::Result<()> {
    let scan = Command::new("ssh-keyscan")
        .args(["-p", &claim.ssh_port.to_string(), &claim.ssh_host])
        .output()?;
    if !scan.status.success() || scan.stdout.is_empty() {
        anyhow::bail!("ssh-keyscan failed")
    }
    let fingerprint = Command::new("ssh-keygen")
        .args(["-lf", "-"])
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .spawn();
    let mut child = fingerprint?;
    child.stdin.take().unwrap().write_all(&scan.stdout)?;
    let output = child.wait_with_output()?;
    let observed = String::from_utf8_lossy(&output.stdout);
    if !observed.contains(&claim.ssh_host_fingerprint) {
        anyhow::bail!("Gateway SSH fingerprint does not match the pairing response")
    }
    fs::write(ssh_dir.join("farpilot_known_hosts"), scan.stdout)?;
    Ok(())
}

fn write_ssh_profile(claim: &ClaimResponse, key_path: &Path, ssh_dir: &Path) -> anyhow::Result<()> {
    let alias = format!("farpilot-{}", claim.host_id);
    let profile = format!(
        "Host {alias}\n  HostName {}\n  Port {}\n  User {}\n  IdentityFile {}\n  IdentitiesOnly yes\n  StrictHostKeyChecking yes\n  UserKnownHostsFile {}\n",
        claim.ssh_host,
        claim.ssh_port,
        claim.ssh_username,
        key_path.display(),
        ssh_dir.join("farpilot_known_hosts").display(),
    );
    let include_path = ssh_dir.join("farpilot_config");
    fs::write(&include_path, profile)?;
    let main_config = ssh_dir.join("config");
    let include = format!("Include {}", include_path.display());
    let existing = fs::read_to_string(&main_config).unwrap_or_default();
    fs::write(main_config, config_with_global_include(&existing, &include))?;
    Ok(())
}

fn config_with_global_include(existing: &str, include: &str) -> String {
    let body = existing
        .lines()
        .filter(|line| line.trim() != include)
        .collect::<Vec<_>>()
        .join("\n");
    let body = body.trim_matches('\n');
    if body.is_empty() {
        format!("{include}\n")
    } else {
        format!("{include}\n\n{body}\n")
    }
}

#[cfg(test)]
mod tests {
    use super::config_with_global_include;

    #[test]
    fn farpilot_include_is_global_and_idempotent() {
        let include = "Include /home/polly/.ssh/farpilot_config";
        let existing = "Host example\n  HostName example.com\nInclude /home/polly/.ssh/farpilot_config\n";
        let updated = config_with_global_include(existing, include);
        assert!(updated.starts_with(&format!("{include}\n\nHost example")));
        assert_eq!(updated.matches(include).count(), 1);
        assert_eq!(config_with_global_include(&updated, include), updated);
    }
}

fn home_dir() -> anyhow::Result<PathBuf> {
    std::env::var_os("HOME")
        .map(PathBuf::from)
        .ok_or_else(|| anyhow::anyhow!("HOME is not set"))
}
