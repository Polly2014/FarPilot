use clap::Parser;

#[derive(Debug, Parser)]
#[command(
    name = "farpilot",
    version,
    about = "Pilot persistent agents from anywhere"
)]
struct Cli {}

fn main() {
    Cli::parse();
}
