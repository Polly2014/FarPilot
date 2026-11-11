#[cfg(unix)]
mod unix {
    use std::io;
    use std::os::fd::AsRawFd;
    use std::path::Path;
    use std::sync::Arc;

    use anyhow::{Context, bail};
    use farpilot_gateway::attach::AttachService;
    use farpilot_gateway::config::GatewayConfig;
    use farpilot_gateway::host_ws::{HostWsState, build_host_ws_router};
    use farpilot_gateway::local_attach::{
        LocalAttachFrame, read_frame, serve_local_attach, write_frame,
    };
    use farpilot_gateway::pairing_http::{GatewayHttpState, build_router};
    use farpilot_gateway::store::GatewayStore;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio::net::{TcpListener, UnixListener, UnixStream};
    use tokio::sync::Mutex;

    pub async fn run_serve(
        bind: &str,
        database_url: &str,
        socket_path: &Path,
    ) -> anyhow::Result<()> {
        let store = GatewayStore::connect(database_url).await?;
        let config = GatewayConfig::from_env()?;
        let pairing_base_url = format!("https://{}", config.public_ssh_host);
        let host_state = HostWsState::new(store.clone()).with_pairing_base_url(pairing_base_url);
        let broker = host_state.broker();
        let app = build_router(GatewayHttpState::new(store, config))
            .merge(build_host_ws_router(host_state));

        if let Some(parent) = socket_path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        if socket_path.exists() {
            std::fs::remove_file(socket_path)?;
        }
        let unix_listener = UnixListener::bind(socket_path)?;
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(socket_path, std::fs::Permissions::from_mode(0o600))?;
        let local_attach = tokio::spawn(serve_local_attach(
            unix_listener,
            AttachService::new(broker),
        ));

        let tcp_listener = TcpListener::bind(bind).await?;
        let http = axum::serve(
            tcp_listener,
            app.into_make_service_with_connect_info::<std::net::SocketAddr>(),
        );
        tokio::select! {
            result = http => result?,
            result = local_attach => result??,
        }
        Ok(())
    }

    pub async fn run_attach(device_id: &str, socket_path: &Path) -> anyhow::Result<()> {
        let _raw_mode = RawModeGuard::enable_if_terminal()?;
        let stream = UnixStream::connect(socket_path)
            .await
            .with_context(|| format!("connect to {}", socket_path.display()))?;
        let (cols, rows) = terminal_size().unwrap_or((80, 24));
        let (mut reader, writer) = stream.into_split();
        let writer = Arc::new(Mutex::new(writer));
        write_frame(
            &mut *writer.lock().await,
            &LocalAttachFrame::Hello {
                device_id: device_id.to_owned(),
                cols,
                rows,
            },
        )
        .await?;

        let input_writer = writer.clone();
        let input_task = tokio::spawn(async move {
            let mut stdin = tokio::io::stdin();
            let mut buffer = vec![0_u8; 16 * 1024];
            loop {
                let count = stdin.read(&mut buffer).await?;
                if count == 0 {
                    write_frame(&mut *input_writer.lock().await, &LocalAttachFrame::Eof).await?;
                    return Ok::<(), io::Error>(());
                }
                write_frame(
                    &mut *input_writer.lock().await,
                    &LocalAttachFrame::Input(buffer[..count].to_vec().into()),
                )
                .await?;
            }
        });

        let resize_task = spawn_resize_forwarder(writer.clone());
        let mut stdout = tokio::io::stdout();
        let result = loop {
            match read_frame(&mut reader).await? {
                Some(LocalAttachFrame::Output(bytes)) => {
                    stdout.write_all(&bytes).await?;
                    stdout.flush().await?;
                }
                Some(LocalAttachFrame::Closed) | None => break Ok(()),
                Some(LocalAttachFrame::Error(message)) => bail!(message),
                Some(_) => bail!("Gateway sent an invalid local attach frame"),
            }
        };
        input_task.abort();
        resize_task.abort();
        result
    }

    fn spawn_resize_forwarder(
        writer: Arc<Mutex<tokio::net::unix::OwnedWriteHalf>>,
    ) -> tokio::task::JoinHandle<io::Result<()>> {
        tokio::spawn(async move {
            let mut signal =
                tokio::signal::unix::signal(tokio::signal::unix::SignalKind::window_change())?;
            while signal.recv().await.is_some() {
                if let Some((cols, rows)) = terminal_size() {
                    write_frame(
                        &mut *writer.lock().await,
                        &LocalAttachFrame::Resize { cols, rows },
                    )
                    .await?;
                }
            }
            Ok(())
        })
    }

    fn terminal_size() -> Option<(u16, u16)> {
        let mut size = libc::winsize {
            ws_row: 0,
            ws_col: 0,
            ws_xpixel: 0,
            ws_ypixel: 0,
        };
        let result = unsafe { libc::ioctl(libc::STDIN_FILENO, libc::TIOCGWINSZ, &mut size) };
        (result == 0 && size.ws_col > 0 && size.ws_row > 0).then_some((size.ws_col, size.ws_row))
    }

    struct RawModeGuard {
        original: Option<libc::termios>,
    }

    impl RawModeGuard {
        fn enable_if_terminal() -> io::Result<Self> {
            let fd = std::io::stdin().as_raw_fd();
            if unsafe { libc::isatty(fd) } != 1 {
                return Ok(Self { original: None });
            }
            let mut original = std::mem::MaybeUninit::<libc::termios>::uninit();
            if unsafe { libc::tcgetattr(fd, original.as_mut_ptr()) } != 0 {
                return Err(io::Error::last_os_error());
            }
            let original = unsafe { original.assume_init() };
            let mut raw = original;
            unsafe { libc::cfmakeraw(&mut raw) };
            if unsafe { libc::tcsetattr(fd, libc::TCSANOW, &raw) } != 0 {
                return Err(io::Error::last_os_error());
            }
            Ok(Self {
                original: Some(original),
            })
        }
    }

    impl Drop for RawModeGuard {
        fn drop(&mut self) {
            if let Some(original) = &self.original {
                unsafe {
                    libc::tcsetattr(libc::STDIN_FILENO, libc::TCSANOW, original);
                }
            }
        }
    }
}

#[cfg(unix)]
pub use unix::{run_attach, run_serve};

pub async fn create_enrollment(database_url: &str) -> anyhow::Result<String> {
    use std::time::{Duration, SystemTime};

    use farpilot_core::pairing::PairingToken;
    use farpilot_gateway::store::GatewayStore;

    let store = GatewayStore::connect(database_url).await?;
    let token = PairingToken::generate("operator", SystemTime::now(), Duration::from_secs(300));
    store.insert_host_enrollment_token(token.record()).await?;
    Ok(token.secret().to_owned())
}

#[cfg(not(unix))]
pub async fn run_attach(_device_id: &str, _socket_path: &std::path::Path) -> anyhow::Result<()> {
    anyhow::bail!("gateway attach is supported only on Unix Gateway hosts")
}

#[cfg(not(unix))]
pub async fn run_serve(
    _bind: &str,
    _database_url: &str,
    _socket_path: &std::path::Path,
) -> anyhow::Result<()> {
    anyhow::bail!("gateway serve is supported only on Unix Gateway hosts")
}
