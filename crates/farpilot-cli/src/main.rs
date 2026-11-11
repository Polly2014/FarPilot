mod device_cmd;
mod gateway_cmd;
mod host_cmd;
mod pair_cmd;
#[cfg(windows)]
mod qr;

use std::path::PathBuf;

use clap::{Parser, Subcommand};
use url::Url;

#[derive(Debug, Parser)]
#[command(
    name = "farpilot",
    version,
    about = "Pilot persistent agents from anywhere"
)]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Debug, Subcommand)]
enum Command {
    /// Configure and run the outbound Windows Host.
    Host {
        #[command(subcommand)]
        command: HostCommand,
    },
    /// Operate the Linux Gateway.
    Gateway {
        #[command(subcommand)]
        command: GatewayCommand,
    },
    /// Pair this client using a short code or pairing URL.
    Pair { code_or_url: String },
    /// List paired client devices.
    Devices,
    /// Revoke one paired client device.
    Revoke {
        device_id: String,
        #[arg(long)]
        yes: bool,
    },
}

#[derive(Debug, Subcommand)]
enum HostCommand {
    /// Enroll this machine and create its local Host configuration.
    Setup {
        #[arg(long, value_parser = parse_https_url)]
        gateway: Url,
        #[arg(long)]
        enrollment_code: String,
        #[arg(long)]
        name: String,
    },
    /// Start the outbound Host connection loop.
    Start,
    /// Show local Host and Gateway connection status.
    Status,
}

#[derive(Debug, Subcommand)]
enum GatewayCommand {
    /// Start HTTP/WSS and local Attach services.
    Serve {
        #[arg(long, default_value = "127.0.0.1:8787")]
        bind: String,
        #[arg(
            long,
            env = "FARPILOT_DATABASE_URL",
            default_value = "sqlite://farpilot.db"
        )]
        database_url: String,
        #[arg(
            long,
            env = "FARPILOT_GATEWAY_SOCKET",
            default_value = "/run/farpilot/gateway.sock"
        )]
        socket: PathBuf,
    },
    /// Manage one-time Host enrollment codes.
    Enrollment {
        #[command(subcommand)]
        command: EnrollmentCommand,
    },
    /// Attach an authorized SSH device to its FarPilot Host.
    Attach {
        #[arg(long)]
        device_id: String,
        #[arg(
            long,
            env = "FARPILOT_GATEWAY_SOCKET",
            default_value = "/run/farpilot/gateway.sock"
        )]
        socket: PathBuf,
    },
}

#[derive(Debug, Subcommand)]
enum EnrollmentCommand {
    /// Create a short-lived Host enrollment code.
    Create,
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    match Cli::parse().command {
        Command::Host {
            command:
                HostCommand::Setup {
                    gateway,
                    enrollment_code,
                    name,
                },
        } => host_cmd::setup(gateway, &enrollment_code, &name).await,
        Command::Host {
            command: HostCommand::Start,
        } => host_cmd::start().await,
        Command::Host {
            command: HostCommand::Status,
        } => host_cmd::status(),
        Command::Gateway {
            command: GatewayCommand::Attach { device_id, socket },
        } => gateway_cmd::run_attach(&device_id, &socket).await,
        Command::Gateway {
            command:
                GatewayCommand::Serve {
                    bind,
                    database_url,
                    socket,
                },
        } => gateway_cmd::run_serve(&bind, &database_url, &socket).await,
        Command::Gateway {
            command:
                GatewayCommand::Enrollment {
                    command: EnrollmentCommand::Create,
                },
        } => {
            let database_url = std::env::var("FARPILOT_DATABASE_URL")
                .unwrap_or_else(|_| "sqlite://farpilot.db".into());
            println!("{}", gateway_cmd::create_enrollment(&database_url).await?);
            Ok(())
        }
        Command::Pair { code_or_url } => pair_cmd::pair(&code_or_url).await,
        Command::Devices => device_cmd::list().await,
        Command::Revoke { device_id, yes } => device_cmd::revoke(&device_id, yes).await,
    }
}

fn parse_https_url(value: &str) -> Result<Url, String> {
    let url = Url::parse(value).map_err(|error| error.to_string())?;
    if url.scheme() != "https" || url.host_str().is_none() {
        return Err("Gateway URL must use https://".into());
    }
    if url.query().is_some() || url.fragment().is_some() {
        return Err("Gateway URL must not contain a query or fragment".into());
    }
    Ok(url)
}
