mod gateway_cmd;

use std::path::PathBuf;

use clap::{Parser, Subcommand};

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
    /// Operate the Linux Gateway.
    Gateway {
        #[command(subcommand)]
        command: GatewayCommand,
    },
}

#[derive(Debug, Subcommand)]
enum GatewayCommand {
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

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    match Cli::parse().command {
        Command::Gateway {
            command: GatewayCommand::Attach { device_id, socket },
        } => gateway_cmd::run_attach(&device_id, &socket).await,
    }
}
