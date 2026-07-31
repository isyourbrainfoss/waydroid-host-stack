//! waydroid-bt-host — BlueZ-backed bridge for Waydroid Bluetooth (LE-first).

mod bluez;
mod discovery;
mod ipc;
mod policy;
mod service;

use std::path::PathBuf;
use std::sync::Arc;

use anyhow::{Context, Result};
use clap::Parser;
use tracing::info;
use tracing_subscriber::EnvFilter;

use crate::bluez::{discovery_loop, BlueZ};
use crate::ipc::IpcServer;
use crate::policy::{PowerPolicy, ScanPolicy};
use crate::service::BridgeService;

const DEFAULT_SOCKET: &str = "/run/waydroid-bt/host.sock";

#[derive(Debug, Parser)]
#[command(
    name = "waydroid-bt-host",
    about = "Invisible host bridge: Waydroid Bluetooth backend over BlueZ"
)]
struct Args {
    /// Unix socket path (bind-mounted into Waydroid LXC).
    #[arg(long, env = "WAYDROID_BT_SOCKET", default_value = DEFAULT_SOCKET)]
    socket: PathBuf,

    /// Skip BlueZ connection (IPC only; for protocol smoke tests).
    #[arg(long, default_value_t = false)]
    dry_run: bool,
}

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| EnvFilter::new("info,waydroid_bt_host=debug")),
        )
        .with_target(true)
        .init();

    let args = Args::parse();
    let version = env!("CARGO_PKG_VERSION").to_string();
    info!(
        version = %version,
        socket = %args.socket.display(),
        "starting waydroid-bt-host"
    );

    let power = PowerPolicy::new();
    let scan = Arc::new(ScanPolicy::new());

    let bluez = if args.dry_run {
        info!("dry-run mode: BlueZ not connected");
        // Still need BlueZ for non-dry-run; dry-run is for packaging checks.
        // Connect may fail without adapter — only used when not dry_run.
        return run_dry(args.socket, scan, version).await;
    } else {
        BlueZ::connect(power)
            .await
            .context("BlueZ connect failed — is bluetooth.service running?")?
    };

    let service = Arc::new(BridgeService::new(
        bluez.clone(),
        Arc::clone(&scan),
        version,
    ));

    // Discovery worker
    let (stop_tx, stop_rx) = tokio::sync::watch::channel(false);
    let (adv_tx, mut adv_rx) = tokio::sync::mpsc::channel(256);
    let bluez_disc = bluez.clone();
    let scan_disc = Arc::clone(&scan);
    let disc_handle = tokio::spawn(async move {
        discovery_loop(bluez_disc, stop_rx, adv_tx, scan_disc).await;
    });

    let service_adv = Arc::clone(&service);
    let adv_forward = tokio::spawn(async move {
        while let Some((session_id, snap)) = adv_rx.recv().await {
            service_adv.emit_adv(session_id, snap).await;
        }
    });

    let server = IpcServer::new(args.socket, service);
    let result = server.run().await;

    let _ = stop_tx.send(true);
    disc_handle.abort();
    adv_forward.abort();
    result
}

async fn run_dry(socket: PathBuf, scan: Arc<ScanPolicy>, version: String) -> Result<()> {
    // Minimal service that only answers Ping without BlueZ.
    use waydroid_bt_protocol::{
        envelope, err_response, ok_response, request, response, ErrorCode, PingResponse,
        PROTOCOL_MAJOR, PROTOCOL_MINOR,
    };

    // Dry-run: bind socket and handle ping inline (no BlueZ) for install smoke tests.
    use bytes::BytesMut;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio::net::UnixListener;
    use waydroid_bt_protocol::{encode_frame, try_decode_frame, MAX_FRAME_SIZE};

    if let Some(parent) = socket.parent() {
        std::fs::create_dir_all(parent)?;
    }
    if socket.exists() {
        std::fs::remove_file(&socket)?;
    }
    let listener = UnixListener::bind(&socket)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(&socket, std::fs::Permissions::from_mode(0o666));
    }
    info!(path = %socket.display(), "dry-run IPC listening (Ping only)");

    loop {
        let (stream, _) = listener.accept().await?;
        let version = version.clone();
        let scan = Arc::clone(&scan);
        tokio::spawn(async move {
            let (mut reader, mut writer) = stream.into_split();
            let mut buf = BytesMut::new();
            let mut tmp = [0u8; 4096];
            loop {
                let n = match reader.read(&mut tmp).await {
                    Ok(0) => break,
                    Ok(n) => n,
                    Err(_) => break,
                };
                buf.extend_from_slice(&tmp[..n]);
                if buf.len() > MAX_FRAME_SIZE + 4 {
                    break;
                }
                while let Ok(Some(env)) = try_decode_frame(&mut buf) {
                    let rid = env.request_id;
                    let resp = match env.body {
                        Some(envelope::Body::Request(r)) => match r.op {
                            Some(request::Op::Ping(_)) => ok_response(
                                rid,
                                response::Result::Ping(PingResponse {
                                    protocol_major: PROTOCOL_MAJOR,
                                    protocol_minor: PROTOCOL_MINOR,
                                    host_version: format!("{version}-dry"),
                                }),
                            ),
                            Some(request::Op::StartLeScan(req)) => {
                                let id = scan.start(crate::policy::ScanSession {
                                    service_uuids: req.service_uuids,
                                    addresses: req.addresses,
                                    active: req.active,
                                });
                                ok_response(
                                    rid,
                                    response::Result::StartLeScan(
                                        waydroid_bt_protocol::StartLeScanResponse {
                                            session_id: id,
                                        },
                                    ),
                                )
                            }
                            Some(request::Op::StopLeScan(req)) => {
                                scan.stop(req.session_id);
                                ok_response(
                                    rid,
                                    response::Result::StopLeScan(
                                        waydroid_bt_protocol::StopLeScanResponse {},
                                    ),
                                )
                            }
                            _ => err_response(
                                rid,
                                ErrorCode::Unsupported,
                                "dry-run supports Ping and scan session accounting only",
                            ),
                        },
                        _ => err_response(rid, ErrorCode::InvalidArgument, "expected request"),
                    };
                    if let Ok(frame) = encode_frame(&resp) {
                        let _ = writer.write_all(&frame).await;
                    }
                }
            }
        });
    }
}
