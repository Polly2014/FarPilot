use std::io;

use bytes::Bytes;
use serde::{Deserialize, Serialize};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};

const LOCAL_PROTOCOL_VERSION: u8 = 1;
const HEADER_BYTES: usize = 6;
const MAX_LOCAL_FRAME_BYTES: usize = 256 * 1024;

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum LocalAttachFrame {
    Hello {
        device_id: String,
        cols: u16,
        rows: u16,
    },
    Input(Bytes),
    Resize {
        cols: u16,
        rows: u16,
    },
    Eof,
    Output(Bytes),
    Closed,
    Error(String),
}

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct HelloBody {
    device_id: String,
    cols: u16,
    rows: u16,
}

pub async fn write_frame<W>(writer: &mut W, frame: &LocalAttachFrame) -> io::Result<()>
where
    W: AsyncWrite + Unpin,
{
    let (kind, payload) = encode(frame)?;
    if payload.len() > MAX_LOCAL_FRAME_BYTES {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "local attach frame is too large",
        ));
    }
    let length = u32::try_from(payload.len())
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "frame length overflow"))?;
    writer.write_all(&[LOCAL_PROTOCOL_VERSION, kind]).await?;
    writer.write_all(&length.to_be_bytes()).await?;
    writer.write_all(&payload).await?;
    writer.flush().await
}

pub async fn read_frame<R>(reader: &mut R) -> io::Result<Option<LocalAttachFrame>>
where
    R: AsyncRead + Unpin,
{
    let mut header = [0_u8; HEADER_BYTES];
    match reader.read_exact(&mut header[..1]).await {
        Ok(_) => {}
        Err(error) if error.kind() == io::ErrorKind::UnexpectedEof => return Ok(None),
        Err(error) => return Err(error),
    }
    reader.read_exact(&mut header[1..]).await?;
    if header[0] != LOCAL_PROTOCOL_VERSION {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "unsupported local attach protocol version",
        ));
    }
    let length = u32::from_be_bytes(header[2..6].try_into().unwrap()) as usize;
    if length > MAX_LOCAL_FRAME_BYTES {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "local attach frame is too large",
        ));
    }
    let mut payload = vec![0_u8; length];
    reader.read_exact(&mut payload).await?;
    decode(header[1], payload).map(Some)
}

fn encode(frame: &LocalAttachFrame) -> io::Result<(u8, Vec<u8>)> {
    match frame {
        LocalAttachFrame::Hello {
            device_id,
            cols,
            rows,
        } => Ok((
            1,
            serde_json::to_vec(&HelloBody {
                device_id: device_id.clone(),
                cols: *cols,
                rows: *rows,
            })
            .map_err(invalid_data)?,
        )),
        LocalAttachFrame::Input(bytes) => Ok((2, bytes.to_vec())),
        LocalAttachFrame::Resize { cols, rows } => {
            let mut payload = Vec::with_capacity(4);
            payload.extend_from_slice(&cols.to_be_bytes());
            payload.extend_from_slice(&rows.to_be_bytes());
            Ok((3, payload))
        }
        LocalAttachFrame::Eof => Ok((4, Vec::new())),
        LocalAttachFrame::Output(bytes) => Ok((5, bytes.to_vec())),
        LocalAttachFrame::Closed => Ok((6, Vec::new())),
        LocalAttachFrame::Error(message) => Ok((7, message.as_bytes().to_vec())),
    }
}

fn decode(kind: u8, payload: Vec<u8>) -> io::Result<LocalAttachFrame> {
    match kind {
        1 => {
            let hello: HelloBody = serde_json::from_slice(&payload).map_err(invalid_data)?;
            Ok(LocalAttachFrame::Hello {
                device_id: hello.device_id,
                cols: hello.cols,
                rows: hello.rows,
            })
        }
        2 => Ok(LocalAttachFrame::Input(payload.into())),
        3 if payload.len() == 4 => Ok(LocalAttachFrame::Resize {
            cols: u16::from_be_bytes([payload[0], payload[1]]),
            rows: u16::from_be_bytes([payload[2], payload[3]]),
        }),
        4 if payload.is_empty() => Ok(LocalAttachFrame::Eof),
        5 => Ok(LocalAttachFrame::Output(payload.into())),
        6 if payload.is_empty() => Ok(LocalAttachFrame::Closed),
        7 => String::from_utf8(payload)
            .map(LocalAttachFrame::Error)
            .map_err(invalid_data),
        _ => Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "invalid local attach frame",
        )),
    }
}

fn invalid_data(error: impl std::fmt::Display) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, error.to_string())
}

#[cfg(unix)]
mod unix_server {
    use std::sync::Arc;

    use async_trait::async_trait;
    use bytes::Bytes;
    use tokio::net::{UnixListener, UnixStream};
    use tokio::sync::{Mutex, mpsc};

    use super::{LocalAttachFrame, read_frame, write_frame};
    use crate::attach::{AttachIo, AttachService};

    pub async fn serve(listener: UnixListener, service: AttachService) -> io::Result<()> {
        loop {
            let (stream, _) = listener.accept().await?;
            let service = service.clone();
            tokio::spawn(async move {
                let _ = handle_connection(stream, service).await;
            });
        }
    }

    async fn handle_connection(stream: UnixStream, service: AttachService) -> io::Result<()> {
        let (mut reader, writer) = stream.into_split();
        let Some(LocalAttachFrame::Hello {
            device_id,
            cols,
            rows,
        }) = read_frame(&mut reader).await?
        else {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "local attach connection must start with Hello",
            ));
        };
        let (input_tx, input_rx) = mpsc::channel(16);
        let (resize_tx, resize_rx) = mpsc::channel(16);
        let writer = Arc::new(Mutex::new(writer));
        let io = Arc::new(LocalServerIo {
            input: Mutex::new(input_rx),
            resize: Mutex::new(resize_rx),
            writer: writer.clone(),
        });
        let reader_task = tokio::spawn(async move {
            while let Some(frame) = read_frame(&mut reader).await? {
                match frame {
                    LocalAttachFrame::Input(bytes) => {
                        if input_tx.send(Some(bytes)).await.is_err() {
                            break;
                        }
                    }
                    LocalAttachFrame::Resize { cols, rows } => {
                        if resize_tx.send(Some((cols, rows))).await.is_err() {
                            break;
                        }
                    }
                    LocalAttachFrame::Eof => {
                        let _ = input_tx.send(None).await;
                        break;
                    }
                    _ => {
                        return Err(io::Error::new(
                            io::ErrorKind::InvalidData,
                            "invalid client-to-Gateway local frame",
                        ));
                    }
                }
            }
            Ok::<(), io::Error>(())
        });

        let result = service.attach_device(&device_id, io, cols, rows).await;
        let final_frame = match result {
            Ok(()) => LocalAttachFrame::Closed,
            Err(error) => LocalAttachFrame::Error(error.to_string()),
        };
        let _ = write_frame(&mut *writer.lock().await, &final_frame).await;
        reader_task.abort();
        Ok(())
    }

    struct LocalServerIo {
        input: Mutex<mpsc::Receiver<Option<Bytes>>>,
        resize: Mutex<mpsc::Receiver<Option<(u16, u16)>>>,
        writer: Arc<Mutex<tokio::net::unix::OwnedWriteHalf>>,
    }

    #[async_trait]
    impl AttachIo for LocalServerIo {
        async fn read_input(&self) -> anyhow::Result<Option<Bytes>> {
            Ok(self.input.lock().await.recv().await.flatten())
        }

        async fn write_output(&self, bytes: &[u8]) -> anyhow::Result<()> {
            write_frame(
                &mut *self.writer.lock().await,
                &LocalAttachFrame::Output(Bytes::copy_from_slice(bytes)),
            )
            .await?;
            Ok(())
        }

        async fn next_resize(&self) -> anyhow::Result<Option<(u16, u16)>> {
            Ok(self.resize.lock().await.recv().await.flatten())
        }
    }

    use std::io;
}

#[cfg(unix)]
pub use unix_server::serve as serve_local_attach;
