//! Unix socket server: length-prefixed protobuf envelopes.

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::Arc;

use anyhow::{Context, Result};
use bytes::BytesMut;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{UnixListener, UnixStream};
use tokio::sync::mpsc;
use tracing::{error, info, warn};
use waydroid_bt_protocol::{encode_frame, try_decode_frame, Envelope, MAX_FRAME_SIZE};

use crate::service::{
    is_keepalive_name, is_passive_connect, request_kind, BridgeService, RequestKind,
};

/// Guest HAL keepalive connections currently attached (normally 0 or 1).
static KEEPALIVE_CLIENTS: AtomicUsize = AtomicUsize::new(0);
/// A keepalive has attached at least once since this bridge started.
static KEEPALIVE_EVER: AtomicBool = AtomicBool::new(false);

/// Status file next to the socket for the host-side watchdog
/// (`waydroid-bt-attach-watchdog.sh`): `keepalive=<n>`, `ever=<0|1>` (a
/// keepalive attached since bridge start) and `changed=<unix s>`.
/// No addresses or other personal data.
pub(crate) fn status_text(keepalive: usize, ever: bool, changed_unix: u64) -> String {
    format!(
        "keepalive={keepalive}\never={}\nchanged={changed_unix}\n",
        u8::from(ever)
    )
}

fn write_status(dir: &Path, keepalive: usize) {
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let tmp = dir.join(".bridge-status.tmp");
    let dst = dir.join("bridge-status");
    let ever = KEEPALIVE_EVER.load(Ordering::SeqCst);
    let res = std::fs::write(&tmp, status_text(keepalive, ever, now))
        .and_then(|_| std::fs::rename(&tmp, &dst));
    if let Err(e) = res {
        warn!(error = %e, "cannot write bridge-status");
    }
}

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
        let status_dir: Arc<PathBuf> = Arc::new(
            self.path
                .parent()
                .map(Path::to_path_buf)
                .unwrap_or_else(|| PathBuf::from("/run/waydroid-bt")),
        );
        KEEPALIVE_CLIENTS.store(0, Ordering::SeqCst);
        write_status(&status_dir, 0);

        loop {
            match listener.accept().await {
                Ok((stream, _addr)) => {
                    info!("guest client connected");
                    let service = Arc::clone(&self.service);
                    let status_dir = Arc::clone(&status_dir);
                    tokio::spawn(async move {
                        if let Err(e) = handle_client(stream, service, status_dir).await {
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

async fn handle_client(
    stream: UnixStream,
    service: Arc<BridgeService>,
    status_dir: Arc<PathBuf>,
) -> Result<()> {
    let (mut reader, writer) = stream.into_split();
    let writer = Arc::new(tokio::sync::Mutex::new(writer));

    // Outbound events from service → this client (scan reports / GATT notifies).
    // The sink is registered lazily on the first non-Ping request: a client
    // that only pings (the guest HAL keepalive, which stays attached for the
    // whole Android session) never receives events and never counts as an
    // active guest, so "last guest gone" cleanup still stops host discovery.
    let (event_tx, mut event_rx) = mpsc::channel::<Envelope>(128);
    let mut client_id: Option<u64> = None;
    let mut keepalive = false;
    let link_owner = service.next_link_owner_id();

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
    let result: Result<()> = async {
        'outer: loop {
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
                        let passive = is_passive_connect(&env);
                        match request_kind(&env) {
                            RequestKind::Ping(name) => {
                                if !keepalive && is_keepalive_name(&name) {
                                    keepalive = true;
                                    KEEPALIVE_EVER.store(true, Ordering::SeqCst);
                                    let n = KEEPALIVE_CLIENTS.fetch_add(1, Ordering::SeqCst) + 1;
                                    info!(clients = n, "guest HAL keepalive attached");
                                    write_status(&status_dir, n);
                                }
                            }
                            _ => {
                                // A passive wait may last minutes: register the
                                // event sink only after it (no fan-out while
                                // the client just waits).
                                if client_id.is_none() && !passive {
                                    client_id =
                                        Some(service.register_event_sink(event_tx.clone()).await);
                                }
                            }
                        }
                        // Handle requests sequentially for simpler device state.
                        let handled = if passive {
                            // Watch the socket while waiting: EOF (guest
                            // cancelled LE Create Connection and shut the
                            // socket down) drops the wait, which disarms the
                            // kernel auto-connect entry.
                            let fut = service.handle_from(link_owner, env);
                            tokio::pin!(fut);
                            let mut gone = false;
                            let r = loop {
                                tokio::select! {
                                    r = &mut fut => break Some(r),
                                    rd = reader.read(&mut tmp), if !gone => match rd {
                                        Ok(0) | Err(_) => { gone = true; break None; }
                                        Ok(n) => buf.extend_from_slice(&tmp[..n]),
                                    },
                                }
                            };
                            if gone {
                                info!("passive connect cancelled: guest client gone");
                                break 'outer;
                            }
                            if client_id.is_none() {
                                client_id =
                                    Some(service.register_event_sink(event_tx.clone()).await);
                            }
                            r
                        } else {
                            Some(service.handle_from(link_owner, env).await)
                        };
                        match handled {
                            Some(Ok(Some(resp))) => {
                                write_envelope(&writer, &resp).await?;
                            }
                            Some(Ok(None)) | None => {}
                            Some(Err(e)) => {
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
        Ok(())
    }
    .await;

    // Always clean up, also after an I/O or decode error.
    if keepalive {
        let n = KEEPALIVE_CLIENTS
            .fetch_sub(1, Ordering::SeqCst)
            .saturating_sub(1);
        info!(clients = n, "guest HAL keepalive detached");
        write_status(&status_dir, n);
    }
    service.release_client_links(link_owner).await;
    if let Some(id) = client_id {
        service.unregister_event_sink(id).await;
    }
    event_task.abort();
    result
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn status_text_format() {
        assert_eq!(status_text(1, true, 42), "keepalive=1\never=1\nchanged=42\n");
        assert_eq!(status_text(0, false, 7), "keepalive=0\never=0\nchanged=7\n");
    }

    #[test]
    fn write_status_atomic_file() {
        let d = tempfile::tempdir().unwrap();
        write_status(d.path(), 1);
        let t = std::fs::read_to_string(d.path().join("bridge-status")).unwrap();
        assert!(t.starts_with("keepalive=1\never="));
        assert!(t.contains("\nchanged="));
        assert!(!d.path().join(".bridge-status.tmp").exists());
    }
}

/// Ensure parent directory exists (used by tests / install scripts).
#[allow(dead_code)]
pub fn ensure_socket_dir(path: &Path) -> Result<()> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    Ok(())
}
