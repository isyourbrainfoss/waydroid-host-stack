//! CLI: send Ping (and optional GetAdapterInfo) to waydroid-bt-host.

use std::path::PathBuf;
use std::time::Duration;

use anyhow::{bail, Context, Result};
use bytes::BytesMut;
use clap::Parser;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::UnixStream;
use waydroid_bt_protocol::{
    encode_frame, envelope, request, try_decode_frame, Envelope, GetAdapterInfoRequest, PingRequest,
    Request, PROTOCOL_MAJOR,
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

    Ok(())
}

async fn read_envelope(stream: &mut UnixStream) -> Result<Envelope> {
    let mut buf = BytesMut::with_capacity(1024);
    let mut tmp = [0u8; 4096];
    let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
    loop {
        if tokio::time::Instant::now() > deadline {
            bail!("timeout waiting for response");
        }
        let n = tokio::time::timeout(Duration::from_secs(2), stream.read(&mut tmp))
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
