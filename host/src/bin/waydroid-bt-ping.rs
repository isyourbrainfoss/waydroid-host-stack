//! CLI: send Ping (and optional GetAdapterInfo / ConnectLe) to waydroid-bt-host.

use std::path::PathBuf;
use std::time::Duration;

use anyhow::{bail, Context, Result};
use bytes::BytesMut;
use clap::Parser;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::UnixStream;
use waydroid_bt_protocol::{
    encode_frame, envelope, request, try_decode_frame, BtAddress, ConnectLeRequest, Envelope,
    GetAdapterInfoRequest, PingRequest, Request, PROTOCOL_MAJOR,
};

#[derive(Parser, Debug)]
struct Args {
    #[arg(long, default_value = "/run/waydroid-bt/host.sock")]
    socket: PathBuf,

    #[arg(long, default_value = "waydroid-bt-ping")]
    client_name: String,

    /// Also request adapter info (requires live BlueZ host, not dry-run).
    #[arg(long, default_value_t = false)]
    adapter: bool,

    /// Desk/phone test: ConnectLe to this address (prints only the result
    /// code and error text, never the address), then Disconnect is NOT sent.
    #[arg(long)]
    connect_le: Option<String>,

    /// ConnectLe timeout_ms (0 = host default).
    #[arg(long, default_value_t = 0)]
    connect_timeout_ms: u32,
}

#[tokio::main]
async fn main() -> Result<()> {
    let args = Args::parse();
    let mut stream = UnixStream::connect(&args.socket)
        .await
        .with_context(|| format!("connect {}", args.socket.display()))?;

    let ping = Envelope {
        request_id: 1,
        body: Some(envelope::Body::Request(Request {
            op: Some(request::Op::Ping(PingRequest {
                client_name: args.client_name,
            })),
        })),
    };
    let frame = encode_frame(&ping)?;
    stream.write_all(&frame).await?;

    let env = read_envelope(&mut stream).await?;
    match env.body {
        Some(envelope::Body::Response(r)) => {
            println!(
                "Ping OK error={} msg={:?} result={:?}",
                r.error, r.error_message, r.result
            );
            if let Some(waydroid_bt_protocol::response::Result::Ping(p)) = r.result {
                println!(
                    "  protocol={}.{} host={}",
                    p.protocol_major, p.protocol_minor, p.host_version
                );
                if p.protocol_major != PROTOCOL_MAJOR {
                    bail!("protocol major mismatch");
                }
            }
        }
        other => bail!("unexpected response: {other:?}"),
    }

    if args.adapter {
        let req = Envelope {
            request_id: 2,
            body: Some(envelope::Body::Request(Request {
                op: Some(request::Op::GetAdapterInfo(GetAdapterInfoRequest {})),
            })),
        };
        stream.write_all(&encode_frame(&req)?).await?;
        let env = read_envelope(&mut stream).await?;
        println!("AdapterInfo: {env:?}");
    }

    if let Some(addr) = args.connect_le {
        let req = Envelope {
            request_id: 3,
            body: Some(envelope::Body::Request(Request {
                op: Some(request::Op::ConnectLe(ConnectLeRequest {
                    address: Some(BtAddress {
                        address: addr,
                        address_type: 0,
                    }),
                    timeout_ms: args.connect_timeout_ms,
                    wait_passive: false,
                })),
            })),
        };
        stream.write_all(&encode_frame(&req)?).await?;
        let started = tokio::time::Instant::now();
        loop {
            let env = read_envelope_for(&mut stream, Duration::from_secs(75)).await?;
            if let Some(envelope::Body::Response(r)) = env.body {
                if env.request_id == 3 {
                    println!(
                        "ConnectLe error={} msg={:?} ok={} after={:.1}s",
                        r.error,
                        r.error_message,
                        r.result.is_some(),
                        started.elapsed().as_secs_f32()
                    );
                    break;
                }
            }
        }
    }

    Ok(())
}

async fn read_envelope(stream: &mut UnixStream) -> Result<Envelope> {
    read_envelope_for(stream, Duration::from_secs(5)).await
}

async fn read_envelope_for(stream: &mut UnixStream, wait: Duration) -> Result<Envelope> {
    let mut buf = BytesMut::with_capacity(1024);
    let mut tmp = [0u8; 4096];
    let deadline = tokio::time::Instant::now() + wait;
    loop {
        if tokio::time::Instant::now() > deadline {
            bail!("timeout waiting for response");
        }
        let n = tokio::time::timeout(wait.min(Duration::from_secs(80)), stream.read(&mut tmp))
            .await
            .context("read timeout")??;
        if n == 0 {
            bail!("connection closed");
        }
        buf.extend_from_slice(&tmp[..n]);
        if let Some(env) = try_decode_frame(&mut buf)? {
            return Ok(env);
        }
    }
}
