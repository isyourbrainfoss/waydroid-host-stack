//! Unix socket server: length-prefixed protobuf envelopes.

use std::path::{Path, PathBuf};
use std::sync::Arc;

use anyhow::{Context, Result};
use bytes::BytesMut;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{UnixListener, UnixStream};
use tokio::sync::mpsc;
use tracing::{error, info, warn};
use waydroid_bt_protocol::{encode_frame, try_decode_frame, Envelope, MAX_FRAME_SIZE};

use crate::service::BridgeService;

pub struct IpcServer {
    path: PathBuf,
    service: Arc<BridgeService>,
}

impl IpcServer {
    pub fn new(path: impl Into<PathBuf>, service: Arc<BridgeService>) -> Self {
        Self {
            path: path.into(),
            service,
        }
    }

    pub async fn run(&self) -> Result<()> {
        if let Some(parent) = self.path.parent() {
            std::fs::create_dir_all(parent)
                .with_context(|| format!("create socket dir {}", parent.display()))?;
        }
        if self.path.exists() {
            std::fs::remove_file(&self.path)
                .with_context(|| format!("remove stale socket {}", self.path.display()))?;
        }

        let listener = UnixListener::bind(&self.path)
            .with_context(|| format!("bind {}", self.path.display()))?;
        // World-accessible inside the LXC mount; tighten with group later if needed.
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let _ = std::fs::set_permissions(&self.path, std::fs::Permissions::from_mode(0o666));
        }
        info!(path = %self.path.display(), "IPC listening");

        loop {
            match listener.accept().await {
                Ok((stream, _addr)) => {
                    info!("guest client connected");
                    let service = Arc::clone(&self.service);
                    tokio::spawn(async move {
                        if let Err(e) = handle_client(stream, service).await {
                            warn!(error = %e, "client session ended with error");
                        } else {
                            info!("guest client disconnected");
                        }
                    });
                }
                Err(e) => {
                    error!(error = %e, "accept failed");
                }
            }
        }
    }
}

async fn handle_client(stream: UnixStream, service: Arc<BridgeService>) -> Result<()> {
    let (mut reader, writer) = stream.into_split();
    let writer = Arc::new(tokio::sync::Mutex::new(writer));

    // Outbound events from service → this client (scan reports / GATT notifies)
    let (event_tx, mut event_rx) = mpsc::channel::<Envelope>(128);
    let client_id = service.register_event_sink(event_tx.clone()).await;

    let writer_events = Arc::clone(&writer);
    let event_task = tokio::spawn(async move {
        while let Some(env) = event_rx.recv().await {
            if let Err(e) = write_envelope(&writer_events, &env).await {
                warn!(error = %e, "failed to write event");
                break;
            }
        }
    });

    let mut buf = BytesMut::with_capacity(4096);
    let mut tmp = vec![0u8; 8192];
    loop {
        let n = reader.read(&mut tmp).await?;
        if n == 0 {
            break;
        }
        buf.extend_from_slice(&tmp[..n]);
        if buf.len() > MAX_FRAME_SIZE + 4 {
            anyhow::bail!("input buffer exceeded max frame size");
        }
        loop {
            match try_decode_frame(&mut buf) {
                Ok(Some(env)) => {
                    let service = Arc::clone(&service);
                    let writer = Arc::clone(&writer);
                    // Handle requests sequentially for simpler device state.
                    match service.handle(env).await {
                        Ok(Some(resp)) => {
                            write_envelope(&writer, &resp).await?;
                        }
                        Ok(None) => {}
                        Err(e) => {
                            warn!(error = %e, "handler error");
                        }
                    }
                }
                Ok(None) => break,
                Err(e) => {
                    anyhow::bail!("decode error: {e}");
                }
            }
        }
    }

    service.unregister_event_sink(client_id).await;
    event_task.abort();
    Ok(())
}

async fn write_envelope(
    writer: &tokio::sync::Mutex<tokio::net::unix::OwnedWriteHalf>,
    env: &Envelope,
) -> Result<()> {
    let frame = encode_frame(env).context("encode frame")?;
    let mut w = writer.lock().await;
    w.write_all(&frame).await?;
    w.flush().await?;
    Ok(())
}

/// Ensure parent directory exists (used by tests / install scripts).
#[allow(dead_code)]
pub fn ensure_socket_dir(path: &Path) -> Result<()> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    Ok(())
}
