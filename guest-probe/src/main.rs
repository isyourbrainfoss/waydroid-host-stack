//! Guest/host bridge probe: Ping + GetAdapterInfo (+ optional LE scan / GATT).
//!
//! Blocking (no tokio). Runs as a musl binary staged into the Waydroid mount
//! namespace via `nsenter -m` (see scripts/waydroid-guest-bt-probe.sh).

use std::io::{Read, Write};
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::process::ExitCode;
use std::time::{Duration, Instant};

use bytes::BytesMut;
use clap::Parser;
use waydroid_bt_protocol::{
    encode_frame, envelope, event, request, response, try_decode_frame, AddressType, BondState,
    BtAddress, ConnectLeRequest, CreateBondRequest, DisconnectRequest, Envelope, ErrorCode,
    GattDiscoverRequest, GattReadRequest, GattSetNotifyRequest, GetAdapterInfoRequest,
    ListBondsRequest, PingRequest, Request, StartLeScanRequest, StopLeScanRequest, PROTOCOL_MAJOR,
};

/// Android-style characteristic property bits (subset).
const PROP_READ: u32 = 0x02;
const PROP_NOTIFY: u32 = 0x10;
const PROP_INDICATE: u32 = 0x20;

#[derive(Debug, Parser)]
#[command(
    name = "waydroid-bt-guest-probe",
    about = "Prove guest↔host BT bridge: Ping, GetAdapterInfo, optional LE scan / GATT"
)]
struct Args {
    #[arg(long, default_value = "/run/waydroid-bt/host.sock")]
    socket: PathBuf,

    #[arg(long, default_value = "waydroid-bt-guest-probe")]
    client_name: String,

    /// Fail if adapter is not powered (default true unless --no-require-powered).
    #[arg(long, default_value_t = true)]
    require_powered: bool,

    #[arg(long, default_value_t = false)]
    no_require_powered: bool,

    /// If > 0, start LE scan for this many seconds and count AdvReport events.
    #[arg(long, default_value_t = 0)]
    le_scan_secs: u64,

    /// With --le-scan-secs, do not fail if zero advertisements are seen
    /// (still requires Start/Stop to succeed). Useful offline / RF quiet rooms.
    #[arg(long, default_value_t = false)]
    allow_zero_ads: bool,

    /// Connect LE + GATT discover + read + disconnect for this MAC (e.g. AA:BB:...).
    #[arg(long)]
    gatt_address: Option<String>,

    /// Characteristic UUID to read (default: Device Name 00002a00-0000-1000-8000-00805f9b34fb).
    #[arg(long, default_value = "00002a00-0000-1000-8000-00805f9b34fb")]
    gatt_char_uuid: String,

    /// Optional service UUID scope for the characteristic.
    #[arg(long, default_value = "")]
    gatt_service_uuid: String,

    /// Connect timeout ms for ConnectLe (0 = host default).
    #[arg(long, default_value_t = 20000)]
    gatt_timeout_ms: u32,

    /// If set, a ConnectLe failure is reported as GATT_CONNECT_FAIL but still exit 0
    /// (used for clean error-path proof when no connectable peripheral exists).
    #[arg(long, default_value_t = false)]
    gatt_allow_connect_fail: bool,

    /// Seconds to wait for a GATT notification after subscribe (0 = skip notify attempt).
    #[arg(long, default_value_t = 8)]
    gatt_notify_secs: u64,

    /// After disconnect, attempt a second ConnectLe in the same session.
    #[arg(long, default_value_t = true)]
    gatt_reconnect: bool,

    /// Skip second ConnectLe.
    #[arg(long, default_value_t = false)]
    gatt_no_reconnect: bool,

    /// CreateBond against this MAC via the host bridge (real BlueZ pair path).
    #[arg(long)]
    create_bond: Option<String>,

    /// If set, a CreateBond failure is reported but still exit 0 (agent/PIN blocked).
    #[arg(long, default_value_t = false)]
    allow_bond_fail: bool,

    /// List bonds after other ops (via host ListBonds).
    #[arg(long, default_value_t = false)]
    list_bonds: bool,
}

fn main() -> ExitCode {
    match run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("PROBE_FAIL {e}");
            ExitCode::from(1)
        }
    }
}

fn run() -> Result<(), String> {
    let args = Args::parse();
    let require_powered = args.require_powered && !args.no_require_powered;

    let mut stream = UnixStream::connect(&args.socket)
        .map_err(|e| format!("connect {}: {e}", args.socket.display()))?;
    stream
        .set_read_timeout(Some(Duration::from_secs(5)))
        .map_err(|e| format!("set_read_timeout: {e}"))?;
    stream
        .set_write_timeout(Some(Duration::from_secs(5)))
        .map_err(|e| format!("set_write_timeout: {e}"))?;

    // --- Ping ---
    write_frame(
        &mut stream,
        &Envelope {
            request_id: 1,
            body: Some(envelope::Body::Request(Request {
                op: Some(request::Op::Ping(PingRequest {
                    client_name: args.client_name.clone(),
                })),
            })),
        },
    )?;
    let env = read_envelope(&mut stream, None)?;
    match expect_ok_response(env, "ping")? {
        Some(response::Result::Ping(p)) => {
            if p.protocol_major != PROTOCOL_MAJOR {
                return Err(format!(
                    "protocol major mismatch: got {} want {PROTOCOL_MAJOR}",
                    p.protocol_major
                ));
            }
            println!(
                "PING_OK protocol={}.{} host_version={}",
                p.protocol_major, p.protocol_minor, p.host_version
            );
        }
        other => return Err(format!("ping missing PingResponse: {other:?}")),
    }

    // --- GetAdapterInfo ---
    write_frame(
        &mut stream,
        &Envelope {
            request_id: 2,
            body: Some(envelope::Body::Request(Request {
                op: Some(request::Op::GetAdapterInfo(GetAdapterInfoRequest {})),
            })),
        },
    )?;
    let env = read_envelope(&mut stream, None)?;
    let info = match expect_ok_response(env, "get_adapter_info")? {
        Some(response::Result::GetAdapterInfo(g)) => g
            .info
            .ok_or_else(|| "GetAdapterInfoResponse missing info".to_string())?,
        other => return Err(format!("missing GetAdapterInfo result: {other:?}")),
    };

    let address = info
        .address
        .as_ref()
        .map(|a| a.address.as_str())
        .unwrap_or("");
    let name = if info.alias.is_empty() {
        info.name.as_str()
    } else {
        info.alias.as_str()
    };

    println!(
        "ADAPTER_OK powered={} le_supported={} soft_disabled={} name={:?} address={:?}",
        info.powered, info.le_supported, info.guest_soft_disabled, name, address
    );

    if address.is_empty() {
        return Err("adapter address empty".into());
    }
    if name.is_empty() {
        return Err("adapter name empty".into());
    }
    if require_powered && !info.powered {
        return Err("adapter not powered".into());
    }

    // --- Optional LE scan ---
    if args.le_scan_secs > 0 {
        run_le_scan(&mut stream, args.le_scan_secs, args.allow_zero_ads)?;
    }

    // --- Optional GATT client flow ---
    if let Some(gatt_addr) = args.gatt_address.as_ref() {
        let do_reconnect = args.gatt_reconnect && !args.gatt_no_reconnect;
        match run_gatt(
            &mut stream,
            gatt_addr,
            &args.gatt_char_uuid,
            &args.gatt_service_uuid,
            args.gatt_timeout_ms,
            args.gatt_notify_secs,
            do_reconnect,
        ) {
            Ok(()) => {}
            Err(e) if args.gatt_allow_connect_fail && e.starts_with("CONNECT_FAIL ") => {
                println!("GATT_CONNECT_FAIL {}", e.trim_start_matches("CONNECT_FAIL "));
                println!("GATT_ERROR_PATH_OK");
            }
            Err(e) => return Err(e),
        }
    }

    // --- Optional CreateBond (host BlueZ pair) ---
    if let Some(bond_addr) = args.create_bond.as_ref() {
        match run_create_bond(&mut stream, bond_addr) {
            Ok(state) => {
                println!("CREATE_BOND_OK address={bond_addr} state={state:?}");
            }
            Err(e) if args.allow_bond_fail => {
                println!("CREATE_BOND_FAIL address={bond_addr} err={e}");
                println!("CREATE_BOND_ERROR_PATH_OK");
            }
            Err(e) => return Err(e),
        }
    }

    if args.list_bonds {
        run_list_bonds(&mut stream)?;
    }

    println!("PROBE_OK");
    Ok(())
}

fn run_create_bond(stream: &mut UnixStream, address: &str) -> Result<BondState, String> {
    stream
        .set_read_timeout(Some(Duration::from_secs(90)))
        .map_err(|e| format!("set_read_timeout: {e}"))?;
    let addr_norm = address.trim().to_uppercase();
    write_frame(
        stream,
        &Envelope {
            request_id: 20,
            body: Some(envelope::Body::Request(Request {
                op: Some(request::Op::CreateBond(CreateBondRequest {
                    address: Some(BtAddress {
                        address: addr_norm.clone(),
                        address_type: AddressType::Public as i32,
                    }),
                })),
            })),
        },
    )?;
    loop {
        let env = read_envelope(stream, None)?;
        match env.body {
            Some(envelope::Body::Event(ev)) => {
                if let Some(event::Payload::BondState(bs)) = ev.payload {
                    println!(
                        "BOND_STATE_EVENT address={:?} state={}",
                        bs.address.as_ref().map(|a| a.address.as_str()),
                        bs.state
                    );
                }
                continue;
            }
            Some(envelope::Body::Response(r)) => {
                if r.error != ErrorCode::Ok as i32 {
                    return Err(format!(
                        "create_bond error={} msg={}",
                        r.error, r.error_message
                    ));
                }
                match r.result {
                    Some(response::Result::CreateBond(c)) => {
                        let state = BondState::try_from(c.state).unwrap_or(BondState::None);
                        // prost enums: Bonded=2, Bonding=1, None=0
                        return Ok(state);
                    }
                    other => return Err(format!("create_bond missing response: {other:?}")),
                }
            }
            other => return Err(format!("create_bond unexpected: {other:?}")),
        }
    }
}

fn run_list_bonds(stream: &mut UnixStream) -> Result<(), String> {
    stream
        .set_read_timeout(Some(Duration::from_secs(10)))
        .map_err(|e| format!("set_read_timeout: {e}"))?;
    write_frame(
        stream,
        &Envelope {
            request_id: 21,
            body: Some(envelope::Body::Request(Request {
                op: Some(request::Op::ListBonds(ListBondsRequest {})),
            })),
        },
    )?;
    loop {
        let env = read_envelope(stream, None)?;
        match env.body {
            Some(envelope::Body::Event(_)) => continue,
            Some(envelope::Body::Response(r)) => {
                if r.error != ErrorCode::Ok as i32 {
                    return Err(format!(
                        "list_bonds error={} msg={}",
                        r.error, r.error_message
                    ));
                }
                match r.result {
                    Some(response::Result::ListBonds(lb)) => {
                        println!("LIST_BONDS_OK count={}", lb.devices.len());
                        for d in lb.devices {
                            let a = d
                                .address
                                .as_ref()
                                .map(|x| x.address.as_str())
                                .unwrap_or("?");
                            println!("BOND device={a} name={:?} state={}", d.name, d.state);
                        }
                        return Ok(());
                    }
                    other => return Err(format!("list_bonds missing response: {other:?}")),
                }
            }
            other => return Err(format!("list_bonds unexpected: {other:?}")),
        }
    }
}

fn run_le_scan(stream: &mut UnixStream, secs: u64, allow_zero: bool) -> Result<(), String> {
    write_frame(
        stream,
        &Envelope {
            request_id: 3,
            body: Some(envelope::Body::Request(Request {
                op: Some(request::Op::StartLeScan(StartLeScanRequest {
                    service_uuids: vec![],
                    addresses: vec![],
                    active: true,
                })),
            })),
        },
    )?;
    let env = read_envelope(stream, None)?;
    let session_id = match expect_ok_response(env, "start_le_scan")? {
        Some(response::Result::StartLeScan(s)) => s.session_id,
        other => return Err(format!("start_le_scan missing response: {other:?}")),
    };
    println!("LE_SCAN_START session_id={session_id}");

    let deadline = Instant::now() + Duration::from_secs(secs);
    let mut ads: u32 = 0;
    let mut names: Vec<String> = Vec::new();
    stream
        .set_read_timeout(Some(Duration::from_millis(400)))
        .map_err(|e| format!("set_read_timeout: {e}"))?;

    while Instant::now() < deadline {
        match read_envelope(stream, Some(&mut BytesMut::new())) {
            Ok(env) => {
                if let Some(envelope::Body::Event(ev)) = env.body {
                    if let Some(event::Payload::AdvReport(rep)) = ev.payload {
                        ads += 1;
                        let addr = rep
                            .address
                            .as_ref()
                            .map(|a| a.address.clone())
                            .unwrap_or_default();
                        let n = if rep.name.is_empty() {
                            addr
                        } else {
                            format!("{} ({})", rep.name, addr)
                        };
                        if names.len() < 8 && !names.contains(&n) {
                            names.push(n);
                        }
                    }
                }
            }
            Err(e) if e.contains("timed out") || e.contains("WouldBlock") => continue,
            Err(e) if e.contains("Resource temporarily unavailable") => continue,
            Err(e) => {
                if e.contains("Interrupted") {
                    continue;
                }
                if e.contains("connection closed") {
                    return Err(e);
                }
                if e.contains("os error 11") || e.contains("os error 110") {
                    continue;
                }
                eprintln!("LE_SCAN_READ_NOTE {e}");
            }
        }
    }

    stream
        .set_read_timeout(Some(Duration::from_secs(5)))
        .map_err(|e| format!("set_read_timeout: {e}"))?;

    write_frame(
        stream,
        &Envelope {
            request_id: 4,
            body: Some(envelope::Body::Request(Request {
                op: Some(request::Op::StopLeScan(StopLeScanRequest { session_id })),
            })),
        },
    )?;
    loop {
        let env = read_envelope(stream, None)?;
        match env.body {
            Some(envelope::Body::Response(r)) => {
                if r.error != ErrorCode::Ok as i32 {
                    return Err(format!(
                        "stop_le_scan error={} msg={}",
                        r.error, r.error_message
                    ));
                }
                println!("LE_SCAN_STOP session_id={session_id}");
                break;
            }
            Some(envelope::Body::Event(ev)) => {
                if let Some(event::Payload::AdvReport(_)) = ev.payload {
                    ads += 1;
                }
            }
            other => return Err(format!("unexpected during stop: {other:?}")),
        }
    }

    println!("LE_SCAN_OK ads={} samples={:?}", ads, names);
    if ads == 0 && !allow_zero {
        return Err("LE scan saw 0 advertisements (use --allow-zero-ads if RF quiet)".into());
    }
    Ok(())
}

fn run_gatt(
    stream: &mut UnixStream,
    address: &str,
    char_uuid: &str,
    service_uuid: &str,
    timeout_ms: u32,
    notify_secs: u64,
    do_reconnect: bool,
) -> Result<(), String> {
    // Longer timeout for connect + gatt
    stream
        .set_read_timeout(Some(Duration::from_secs(60)))
        .map_err(|e| format!("set_read_timeout: {e}"))?;

    let addr_norm = address.trim().to_uppercase();
    let (device_id, mtu) = connect_le(stream, 10, &addr_norm, timeout_ms)?;
    println!("GATT_CONNECT_OK device_id={device_id} mtu={mtu}");

    let services = gatt_discover(stream, 11, &device_id).map_err(|e| {
        let _ = disconnect(stream, 99, &device_id);
        e
    })?;

    let mut char_count = 0u32;
    for s in &services {
        char_count += s.characteristics.len() as u32;
        println!(
            "GATT_SERVICE uuid={} primary={} chars={}",
            s.uuid,
            s.primary,
            s.characteristics.len()
        );
        for c in &s.characteristics {
            println!(
                "GATT_CHAR service={} uuid={} properties=0x{:02x}",
                s.uuid, c.uuid, c.properties
            );
        }
    }
    println!(
        "GATT_DISCOVER_OK services={} characteristics={}",
        services.len(),
        char_count
    );
    if services.is_empty() {
        let _ = disconnect(stream, 99, &device_id);
        return Err("gatt_discover returned 0 services".into());
    }
    if char_count == 0 {
        let _ = disconnect(stream, 99, &device_id);
        return Err("gatt_discover returned 0 characteristics".into());
    }

    // Resolve characteristic to read: preferred UUID, else first readable, else first char
    let (svc_uuid, ch_uuid) = pick_characteristic(&services, service_uuid, char_uuid)?;
    println!("GATT_READ_TARGET service={svc_uuid} char={ch_uuid}");

    let value = gatt_read(stream, 12, &device_id, &svc_uuid, &ch_uuid).map_err(|e| {
        let _ = disconnect(stream, 99, &device_id);
        e
    })?;
    if value.is_empty() {
        let _ = disconnect(stream, 99, &device_id);
        return Err("gatt_read returned empty value".into());
    }
    println!(
        "GATT_READ_OK len={} hex_prefix=[{}]",
        value.len(),
        hex_prefix(&value, 32)
    );

    // Notify if a notify/indicate char exists
    if notify_secs > 0 {
        match pick_notify_characteristic(&services) {
            Some((n_svc, n_ch, props)) => {
                println!(
                    "GATT_NOTIFY_TARGET service={n_svc} char={n_ch} properties=0x{props:02x}"
                );
                match try_notify(stream, &device_id, &n_svc, &n_ch, notify_secs) {
                    Ok(n) => {
                        println!("GATT_NOTIFY_OK count={n}");
                    }
                    Err(e) => {
                        println!("GATT_NOTIFY_FAIL err={e}");
                        // Non-fatal if connect/discover/read already succeeded
                        println!("GATT_NOTIFY_UNSUPPORTED_OR_FAIL documented");
                    }
                }
            }
            None => {
                println!("GATT_NOTIFY_NONE no notify/indicate characteristic");
            }
        }
    }

    disconnect(stream, 13, &device_id)?;
    println!("GATT_DISCONNECT_OK device_id={device_id}");

    // Powered still on after disconnect
    match get_adapter_powered(stream, 14) {
        Ok(true) => println!("GATT_HOST_POWERED_OK powered=true"),
        Ok(false) => {
            return Err("host adapter powered=false after disconnect".into());
        }
        Err(e) => println!("GATT_HOST_POWERED_CHECK_FAIL err={e}"),
    }

    if do_reconnect {
        match connect_le(stream, 15, &addr_norm, timeout_ms) {
            Ok((id2, mtu2)) => {
                println!("GATT_RECONNECT_OK device_id={id2} mtu={mtu2}");
                let _ = disconnect(stream, 16, &id2);
                println!("GATT_RECONNECT_DISCONNECT_OK device_id={id2}");
            }
            Err(e) => {
                // Clean non-crash failure is acceptable
                println!("GATT_RECONNECT_FAIL err={e}");
                println!("GATT_RECONNECT_CLEAN_FAIL_OK");
            }
        }
        match get_adapter_powered(stream, 17) {
            Ok(true) => println!("GATT_HOST_POWERED_AFTER_RECONNECT_OK powered=true"),
            Ok(false) => return Err("host adapter powered=false after reconnect path".into()),
            Err(e) => println!("GATT_HOST_POWERED_AFTER_RECONNECT_CHECK_FAIL err={e}"),
        }
    }

    println!("GATT_OK");
    Ok(())
}

fn connect_le(
    stream: &mut UnixStream,
    request_id: u64,
    addr_norm: &str,
    timeout_ms: u32,
) -> Result<(String, u32), String> {
    write_frame(
        stream,
        &Envelope {
            request_id,
            body: Some(envelope::Body::Request(Request {
                op: Some(request::Op::ConnectLe(ConnectLeRequest {
                    address: Some(BtAddress {
                        address: addr_norm.to_string(),
                        address_type: AddressType::Public as i32,
                    }),
                    timeout_ms,
                })),
            })),
        },
    )?;
    loop {
        let env = read_envelope(stream, None)?;
        match env.body {
            Some(envelope::Body::Event(_)) => continue,
            Some(envelope::Body::Response(r)) => {
                if r.error != ErrorCode::Ok as i32 {
                    return Err(format!(
                        "CONNECT_FAIL error={} msg={}",
                        r.error, r.error_message
                    ));
                }
                match r.result {
                    Some(response::Result::ConnectLe(c)) => return Ok((c.device_id, c.mtu)),
                    other => return Err(format!("connect_le missing response: {other:?}")),
                }
            }
            other => return Err(format!("connect_le unexpected: {other:?}")),
        }
    }
}

fn gatt_discover(
    stream: &mut UnixStream,
    request_id: u64,
    device_id: &str,
) -> Result<Vec<waydroid_bt_protocol::GattService>, String> {
    write_frame(
        stream,
        &Envelope {
            request_id,
            body: Some(envelope::Body::Request(Request {
                op: Some(request::Op::GattDiscover(GattDiscoverRequest {
                    device_id: device_id.to_string(),
                })),
            })),
        },
    )?;
    loop {
        let env = read_envelope(stream, None)?;
        match env.body {
            Some(envelope::Body::Event(_)) => continue,
            Some(envelope::Body::Response(r)) => {
                if r.error != ErrorCode::Ok as i32 {
                    return Err(format!(
                        "gatt_discover error={} msg={}",
                        r.error, r.error_message
                    ));
                }
                match r.result {
                    Some(response::Result::GattDiscover(d)) => return Ok(d.services),
                    other => return Err(format!("gatt_discover missing: {other:?}")),
                }
            }
            other => return Err(format!("gatt_discover unexpected: {other:?}")),
        }
    }
}

fn gatt_read(
    stream: &mut UnixStream,
    request_id: u64,
    device_id: &str,
    service_uuid: &str,
    char_uuid: &str,
) -> Result<bytes::Bytes, String> {
    write_frame(
        stream,
        &Envelope {
            request_id,
            body: Some(envelope::Body::Request(Request {
                op: Some(request::Op::GattRead(GattReadRequest {
                    device_id: device_id.to_string(),
                    characteristic_uuid: char_uuid.to_string(),
                    service_uuid: service_uuid.to_string(),
                })),
            })),
        },
    )?;
    loop {
        let env = read_envelope(stream, None)?;
        match env.body {
            Some(envelope::Body::Event(_)) => continue,
            Some(envelope::Body::Response(r)) => {
                if r.error != ErrorCode::Ok as i32 {
                    return Err(format!(
                        "gatt_read error={} msg={}",
                        r.error, r.error_message
                    ));
                }
                match r.result {
                    Some(response::Result::GattRead(rd)) => return Ok(rd.value),
                    other => return Err(format!("gatt_read missing: {other:?}")),
                }
            }
            other => return Err(format!("gatt_read unexpected: {other:?}")),
        }
    }
}

fn try_notify(
    stream: &mut UnixStream,
    device_id: &str,
    service_uuid: &str,
    char_uuid: &str,
    wait_secs: u64,
) -> Result<u32, String> {
    write_frame(
        stream,
        &Envelope {
            request_id: 40,
            body: Some(envelope::Body::Request(Request {
                op: Some(request::Op::GattSetNotify(GattSetNotifyRequest {
                    device_id: device_id.to_string(),
                    characteristic_uuid: char_uuid.to_string(),
                    service_uuid: service_uuid.to_string(),
                    enable: true,
                })),
            })),
        },
    )?;
    // Wait for set-notify response
    loop {
        let env = read_envelope(stream, None)?;
        match env.body {
            Some(envelope::Body::Event(_)) => continue,
            Some(envelope::Body::Response(r)) => {
                if r.error != ErrorCode::Ok as i32 {
                    return Err(format!(
                        "gatt_set_notify error={} msg={}",
                        r.error, r.error_message
                    ));
                }
                break;
            }
            other => return Err(format!("gatt_set_notify unexpected: {other:?}")),
        }
    }
    println!("GATT_NOTIFY_ENABLED service={service_uuid} char={char_uuid}");

    let mut count = 0u32;
    let deadline = Instant::now() + Duration::from_secs(wait_secs);
    stream
        .set_read_timeout(Some(Duration::from_millis(500)))
        .map_err(|e| format!("set_read_timeout notify: {e}"))?;
    while Instant::now() < deadline {
        match read_envelope(stream, None) {
            Ok(env) => match env.body {
                Some(envelope::Body::Event(ev)) => {
                    if let Some(event::Payload::GattNotification(n)) = ev.payload {
                        count += 1;
                        println!(
                            "GATT_NOTIFY_EVENT service={} char={} len={} hex_prefix=[{}]",
                            n.service_uuid,
                            n.characteristic_uuid,
                            n.value.len(),
                            hex_prefix(&n.value, 16)
                        );
                    }
                }
                Some(envelope::Body::Response(_)) => {
                    // ignore stray responses
                }
                _ => {}
            },
            Err(e) if e.contains("timed out") || e.contains("would block") => continue,
            Err(e) => {
                // restore timeout and surface
                let _ = stream.set_read_timeout(Some(Duration::from_secs(60)));
                return Err(e);
            }
        }
    }
    let _ = stream.set_read_timeout(Some(Duration::from_secs(60)));

    // Disable notify (best effort)
    let _ = write_frame(
        stream,
        &Envelope {
            request_id: 41,
            body: Some(envelope::Body::Request(Request {
                op: Some(request::Op::GattSetNotify(GattSetNotifyRequest {
                    device_id: device_id.to_string(),
                    characteristic_uuid: char_uuid.to_string(),
                    service_uuid: service_uuid.to_string(),
                    enable: false,
                })),
            })),
        },
    );
    // Drain one response with short timeout
    stream
        .set_read_timeout(Some(Duration::from_secs(2)))
        .ok();
    let _ = read_envelope(stream, None);
    stream
        .set_read_timeout(Some(Duration::from_secs(60)))
        .ok();

    if count == 0 {
        return Err("no notifications received in wait window".into());
    }
    Ok(count)
}

fn get_adapter_powered(stream: &mut UnixStream, request_id: u64) -> Result<bool, String> {
    write_frame(
        stream,
        &Envelope {
            request_id,
            body: Some(envelope::Body::Request(Request {
                op: Some(request::Op::GetAdapterInfo(GetAdapterInfoRequest {})),
            })),
        },
    )?;
    loop {
        let env = read_envelope(stream, None)?;
        match env.body {
            Some(envelope::Body::Event(_)) => continue,
            Some(envelope::Body::Response(r)) => {
                if r.error != ErrorCode::Ok as i32 {
                    return Err(format!(
                        "get_adapter_info error={} msg={}",
                        r.error, r.error_message
                    ));
                }
                match r.result {
                    Some(response::Result::GetAdapterInfo(g)) => {
                        let info = g
                            .info
                            .ok_or_else(|| "GetAdapterInfo missing info".to_string())?;
                        return Ok(info.powered);
                    }
                    other => return Err(format!("get_adapter_info missing: {other:?}")),
                }
            }
            other => return Err(format!("get_adapter_info unexpected: {other:?}")),
        }
    }
}

fn disconnect(stream: &mut UnixStream, request_id: u64, device_id: &str) -> Result<(), String> {
    write_frame(
        stream,
        &Envelope {
            request_id,
            body: Some(envelope::Body::Request(Request {
                op: Some(request::Op::Disconnect(DisconnectRequest {
                    device_id: device_id.to_string(),
                })),
            })),
        },
    )?;
    loop {
        let env = read_envelope(stream, None)?;
        match env.body {
            Some(envelope::Body::Event(_)) => continue,
            Some(envelope::Body::Response(r)) => {
                if r.error != ErrorCode::Ok as i32 {
                    return Err(format!(
                        "disconnect error={} msg={}",
                        r.error, r.error_message
                    ));
                }
                return Ok(());
            }
            other => return Err(format!("disconnect unexpected: {other:?}")),
        }
    }
}

fn hex_prefix(value: &[u8], max: usize) -> String {
    value
        .iter()
        .take(max)
        .map(|b| format!("{b:02x}"))
        .collect::<Vec<_>>()
        .join(" ")
}

/// Prefer exact char UUID; else first **readable** char; else first characteristic.
fn pick_characteristic(
    services: &[waydroid_bt_protocol::GattService],
    prefer_service: &str,
    prefer_char: &str,
) -> Result<(String, String), String> {
    let prefer_char_l = prefer_char.to_lowercase();
    let prefer_svc_l = prefer_service.to_lowercase();

    // Exact match on char (+ optional service)
    for s in services {
        if !prefer_svc_l.is_empty() && s.uuid.to_lowercase() != prefer_svc_l {
            continue;
        }
        for c in &s.characteristics {
            if c.uuid.to_lowercase() == prefer_char_l {
                return Ok((s.uuid.clone(), c.uuid.clone()));
            }
        }
    }
    // First readable characteristic
    for s in services {
        for c in &s.characteristics {
            if c.properties & PROP_READ != 0 {
                return Ok((s.uuid.clone(), c.uuid.clone()));
            }
        }
    }
    // First characteristic if preferred not found
    for s in services {
        if let Some(c) = s.characteristics.first() {
            return Ok((s.uuid.clone(), c.uuid.clone()));
        }
    }
    Err("no characteristics found to read".into())
}

/// First characteristic with notify or indicate property bits set.
fn pick_notify_characteristic(
    services: &[waydroid_bt_protocol::GattService],
) -> Option<(String, String, u32)> {
    for s in services {
        for c in &s.characteristics {
            if c.properties & (PROP_NOTIFY | PROP_INDICATE) != 0 {
                return Some((s.uuid.clone(), c.uuid.clone(), c.properties));
            }
        }
    }
    None
}

/// Count services / characteristics for pure tests and logging.
fn gatt_tree_counts(services: &[waydroid_bt_protocol::GattService]) -> (usize, usize) {
    let chars = services.iter().map(|s| s.characteristics.len()).sum();
    (services.len(), chars)
}

fn expect_ok_response(
    env: Envelope,
    what: &str,
) -> Result<Option<response::Result>, String> {
    match env.body {
        Some(envelope::Body::Response(r)) if r.error == ErrorCode::Ok as i32 => Ok(r.result),
        Some(envelope::Body::Response(r)) => Err(format!(
            "{what} error={} msg={}",
            r.error, r.error_message
        )),
        Some(envelope::Body::Event(_)) => Err(format!("{what}: expected response, got event")),
        other => Err(format!("{what}: unexpected body {other:?}")),
    }
}

fn write_frame(stream: &mut UnixStream, env: &Envelope) -> Result<(), String> {
    let frame = encode_frame(env).map_err(|e| format!("encode: {e}"))?;
    stream
        .write_all(&frame)
        .map_err(|e| format!("write: {e}"))?;
    Ok(())
}

/// Read one full envelope.
fn read_envelope(
    stream: &mut UnixStream,
    _reuse: Option<&mut BytesMut>,
) -> Result<Envelope, String> {
    let mut buf = BytesMut::with_capacity(4096);
    let mut tmp = [0u8; 8192];
    loop {
        if let Some(env) = try_decode_frame(&mut buf).map_err(|e| format!("decode: {e}"))? {
            return Ok(env);
        }
        let n = match stream.read(&mut tmp) {
            Ok(0) => return Err("connection closed before complete frame".into()),
            Ok(n) => n,
            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                return Err(format!("read timed out / would block: {e}"));
            }
            Err(e) if e.kind() == std::io::ErrorKind::TimedOut => {
                return Err(format!("read timed out: {e}"));
            }
            Err(e) => return Err(format!("read: {e}")),
        };
        buf.extend_from_slice(&tmp[..n]);
        if buf.len() > waydroid_bt_protocol::MAX_FRAME_SIZE + 4 {
            return Err("frame buffer overflow".into());
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use waydroid_bt_protocol::{ok_response, response, GattCharacteristic, GattService, PingResponse, PROTOCOL_MINOR};

    #[test]
    fn encode_ping_roundtrip_via_codec() {
        let ping = Envelope {
            request_id: 7,
            body: Some(envelope::Body::Request(Request {
                op: Some(request::Op::Ping(PingRequest {
                    client_name: "unit".into(),
                })),
            })),
        };
        let frame = encode_frame(&ping).unwrap();
        let mut buf = BytesMut::from(frame.as_slice());
        let decoded = try_decode_frame(&mut buf).unwrap().unwrap();
        assert_eq!(decoded.request_id, 7);
    }

    #[test]
    fn ok_response_ping_shape() {
        let env = ok_response(
            1,
            response::Result::Ping(PingResponse {
                protocol_major: PROTOCOL_MAJOR,
                protocol_minor: PROTOCOL_MINOR,
                host_version: "0.1.0".into(),
            }),
        );
        let frame = encode_frame(&env).unwrap();
        assert!(frame.len() > 4);
    }

    #[test]
    fn encode_start_stop_scan() {
        let start = Envelope {
            request_id: 3,
            body: Some(envelope::Body::Request(Request {
                op: Some(request::Op::StartLeScan(StartLeScanRequest {
                    service_uuids: vec![],
                    addresses: vec![],
                    active: true,
                })),
            })),
        };
        assert!(encode_frame(&start).unwrap().len() > 4);
        let stop = Envelope {
            request_id: 4,
            body: Some(envelope::Body::Request(Request {
                op: Some(request::Op::StopLeScan(StopLeScanRequest { session_id: 1 })),
            })),
        };
        assert!(encode_frame(&stop).unwrap().len() > 4);
    }

    #[test]
    fn encode_gatt_connect_discover_read_disconnect_frames() {
        let connect = Envelope {
            request_id: 10,
            body: Some(envelope::Body::Request(Request {
                op: Some(request::Op::ConnectLe(ConnectLeRequest {
                    address: Some(BtAddress {
                        address: "AA:BB:CC:DD:EE:FF".into(),
                        address_type: AddressType::Public as i32,
                    }),
                    timeout_ms: 15000,
                })),
            })),
        };
        assert!(encode_frame(&connect).unwrap().len() > 4);

        let disc = Envelope {
            request_id: 11,
            body: Some(envelope::Body::Request(Request {
                op: Some(request::Op::GattDiscover(GattDiscoverRequest {
                    device_id: "AA:BB:CC:DD:EE:FF".into(),
                })),
            })),
        };
        assert!(encode_frame(&disc).unwrap().len() > 4);

        let read = Envelope {
            request_id: 12,
            body: Some(envelope::Body::Request(Request {
                op: Some(request::Op::GattRead(GattReadRequest {
                    device_id: "AA:BB:CC:DD:EE:FF".into(),
                    characteristic_uuid: "00002a00-0000-1000-8000-00805f9b34fb".into(),
                    service_uuid: "00001800-0000-1000-8000-00805f9b34fb".into(),
                })),
            })),
        };
        assert!(encode_frame(&read).unwrap().len() > 4);

        let discn = Envelope {
            request_id: 13,
            body: Some(envelope::Body::Request(Request {
                op: Some(request::Op::Disconnect(DisconnectRequest {
                    device_id: "AA:BB:CC:DD:EE:FF".into(),
                })),
            })),
        };
        assert!(encode_frame(&discn).unwrap().len() > 4);
    }

    #[test]
    fn pick_characteristic_prefers_uuid_then_readable() {
        let services = vec![GattService {
            uuid: "00001800-0000-1000-8000-00805f9b34fb".into(),
            handle: 1,
            primary: true,
            characteristics: vec![
                GattCharacteristic {
                    uuid: "00002a00-0000-1000-8000-00805f9b34fb".into(),
                    handle: 2,
                    properties: PROP_READ,
                    descriptors: vec![],
                },
                GattCharacteristic {
                    uuid: "00002a01-0000-1000-8000-00805f9b34fb".into(),
                    handle: 3,
                    properties: PROP_READ,
                    descriptors: vec![],
                },
            ],
        }];
        let (s, c) = pick_characteristic(
            &services,
            "",
            "00002a01-0000-1000-8000-00805f9b34fb",
        )
        .unwrap();
        assert_eq!(s, "00001800-0000-1000-8000-00805f9b34fb");
        assert_eq!(c, "00002a01-0000-1000-8000-00805f9b34fb");

        let (s2, c2) = pick_characteristic(&services, "", "missing-uuid").unwrap();
        assert_eq!(c2, "00002a00-0000-1000-8000-00805f9b34fb");
        assert_eq!(s2, "00001800-0000-1000-8000-00805f9b34fb");
    }

    #[test]
    fn pick_notify_characteristic_finds_notify_bit() {
        let services = vec![GattService {
            uuid: "0000180f-0000-1000-8000-00805f9b34fb".into(),
            handle: 1,
            primary: true,
            characteristics: vec![
                GattCharacteristic {
                    uuid: "00002a19-0000-1000-8000-00805f9b34fb".into(),
                    handle: 2,
                    properties: PROP_READ | PROP_NOTIFY,
                    descriptors: vec![],
                },
            ],
        }];
        let (s, c, p) = pick_notify_characteristic(&services).unwrap();
        assert_eq!(s, "0000180f-0000-1000-8000-00805f9b34fb");
        assert_eq!(c, "00002a19-0000-1000-8000-00805f9b34fb");
        assert_ne!(p & PROP_NOTIFY, 0);

        let none = pick_notify_characteristic(&[GattService {
            uuid: "00001800-0000-1000-8000-00805f9b34fb".into(),
            handle: 1,
            primary: true,
            characteristics: vec![GattCharacteristic {
                uuid: "00002a00-0000-1000-8000-00805f9b34fb".into(),
                handle: 2,
                properties: PROP_READ,
                descriptors: vec![],
            }],
        }]);
        assert!(none.is_none());
    }

    #[test]
    fn gatt_tree_counts_and_hex_prefix() {
        let services = vec![GattService {
            uuid: "s1".into(),
            handle: 0,
            primary: true,
            characteristics: vec![
                GattCharacteristic {
                    uuid: "c1".into(),
                    handle: 0,
                    properties: PROP_READ,
                    descriptors: vec![],
                },
                GattCharacteristic {
                    uuid: "c2".into(),
                    handle: 0,
                    properties: PROP_NOTIFY,
                    descriptors: vec![],
                },
            ],
        }];
        assert_eq!(gatt_tree_counts(&services), (1, 2));
        assert_eq!(hex_prefix(&[0x0a, 0x0b, 0xff], 2), "0a 0b");
    }
}
