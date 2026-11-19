//! Request dispatch: protocol ops → BlueZ + policy.

use std::collections::HashMap;
use std::sync::Arc;
use std::time::Duration;

use anyhow::Result;
use bytes::Bytes;
use futures::StreamExt;
use tokio::sync::{mpsc, Mutex};
use tracing::{debug, info, warn};
use waydroid_bt_protocol::{
    envelope, err_response, event, event_envelope, ok_response, request, response, AdvReportEvent,
    BtAddress, ConnectionState, ConnectionStateEvent, Envelope, ErrorCode, GattNotificationEvent,
    GattReadResponse, PingResponse, PROTOCOL_MAJOR, PROTOCOL_MINOR,
};

use crate::bluez::{BlueZ, PassiveConnectError};
use crate::policy::{ScanPolicy, ScanSession};

pub struct BridgeService {
    bluez: BlueZ,
    scan: Arc<ScanPolicy>,
    /// Multi-client event sinks (scan + ATT may be connected at once).
    /// Keyed by monotonic client id so disconnect of one client does not
    /// steal or abort another client's notify stream.
    event_sinks: Arc<Mutex<HashMap<u64, mpsc::Sender<Envelope>>>>,
    next_client_id: std::sync::atomic::AtomicU64,
    /// Active notify tasks keyed by device_id + char uuid
    notify_tasks: Arc<Mutex<HashMap<String, tokio::task::JoinHandle<()>>>>,
    /// One link-loss watcher per connected LE device_id (upper case). When
    /// BlueZ reports Device1.Connected=false (supervision timeout, car drove
    /// off, remote terminate) the guest gets ConnectionState=Disconnected,
    /// so the HAL can inject an HCI Disconnection Complete like a controller.
    link_watch: Arc<Mutex<HashMap<String, tokio::task::JoinHandle<()>>>>,
    /// LE links opened by ConnectLe, keyed by device_id (upper case) -> the
    /// IPC client that owns it. When that client goes away without a
    /// Disconnect (guest HAL cancelled a pending connect mid-attempt, HAL
    /// crash), the host link is dropped instead of dangling.
    owned_links: Mutex<HashMap<String, u64>>,
    host_version: String,
}

/// What the IPC layer must know about a request before dispatch (pure).
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum RequestKind {
    /// Ping (client name): identification / keepalive. Does not subscribe
    /// to events.
    Ping(String),
    ConnectLe,
    Disconnect(String),
    Other,
}

pub(crate) fn request_kind(env: &Envelope) -> RequestKind {
    match &env.body {
        Some(envelope::Body::Request(r)) => match &r.op {
            Some(request::Op::Ping(p)) => RequestKind::Ping(p.client_name.clone()),
            Some(request::Op::ConnectLe(_)) => RequestKind::ConnectLe,
            Some(request::Op::Disconnect(d)) => RequestKind::Disconnect(d.device_id.clone()),
            _ => RequestKind::Other,
        },
        _ => RequestKind::Other,
    }
}

/// Ping client names ending in "-keepalive" mark the guest HAL's persistent
/// attachment (pure).
pub(crate) fn is_keepalive_name(name: &str) -> bool {
    name.ends_with("-keepalive")
}

/// Default / maximum passive wait for `ConnectLe { wait_passive }`.
pub(crate) const PASSIVE_WAIT_DEFAULT_MS: u32 = 600_000;
pub(crate) const PASSIVE_WAIT_MAX_MS: u32 = 1_800_000;

/// Passive wait duration from the request timeout (pure).
pub(crate) fn passive_wait(timeout_ms: u32) -> Duration {
    let ms = match timeout_ms {
        0 => PASSIVE_WAIT_DEFAULT_MS,
        t => t.min(PASSIVE_WAIT_MAX_MS),
    };
    Duration::from_millis(ms as u64)
}

/// True for `ConnectLe { wait_passive: true }` (pure). Such a request may wait
/// for minutes: the IPC loop watches the socket meanwhile (EOF cancels) and
/// registers the event sink only afterwards, so a waiting client gets no scan
/// or notification fan-out.
pub(crate) fn is_passive_connect(env: &Envelope) -> bool {
    match &env.body {
        Some(envelope::Body::Request(r)) => {
            matches!(&r.op, Some(request::Op::ConnectLe(c)) if c.wait_passive)
        }
        _ => false,
    }
}

/// device_id from a successful ConnectLe response (pure).
pub(crate) fn connect_le_device_id(resp: &Envelope) -> Option<String> {
    match &resp.body {
        Some(envelope::Body::Response(r)) => match &r.result {
            Some(response::Result::ConnectLe(c)) if !c.device_id.is_empty() => {
                Some(c.device_id.to_ascii_uppercase())
            }
            _ => None,
        },
        _ => None,
    }
}

/// ConnectionState=Disconnected event for a lost link (pure — unit tested).
pub(crate) fn link_lost_event(device_id: &str) -> Envelope {
    event_envelope(event::Payload::ConnectionState(ConnectionStateEvent {
        device_id: device_id.to_string(),
        address: None,
        state: ConnectionState::Disconnected as i32,
        reason: "link lost".into(),
    }))
}

/// Links owned by `client` (pure helper — unit tested).
pub(crate) fn links_owned_by(owned: &HashMap<String, u64>, client: u64) -> Vec<String> {
    let mut v: Vec<String> = owned
        .iter()
        .filter(|(_, c)| **c == client)
        .map(|(d, _)| d.clone())
        .collect();
    v.sort();
    v
}

impl BridgeService {
    pub fn new(bluez: BlueZ, scan: Arc<ScanPolicy>, host_version: String) -> Self {
        Self {
            bluez,
            scan,
            event_sinks: Arc::new(Mutex::new(HashMap::new())),
            next_client_id: std::sync::atomic::AtomicU64::new(1),
            notify_tasks: Arc::new(Mutex::new(HashMap::new())),
            link_watch: Arc::new(Mutex::new(HashMap::new())),
            owned_links: Mutex::new(HashMap::new()),
            host_version,
        }
    }

    /// Fresh id for LE-link ownership (one per IPC connection; shares the
    /// event-sink counter so ids never collide).
    pub fn next_link_owner_id(&self) -> u64 {
        self.next_client_id
            .fetch_add(1, std::sync::atomic::Ordering::Relaxed)
    }

    /// Register a guest IPC client for unsolicited events. Returns client id.
    pub async fn register_event_sink(&self, tx: mpsc::Sender<Envelope>) -> u64 {
        let id = self
            .next_client_id
            .fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        self.event_sinks.lock().await.insert(id, tx);
        id
    }

    /// Unregister one client. Does NOT abort notify tasks belonging to other
    /// still-connected clients (previous global unregister killed live pressure
    /// when the scan IPC closed while ATT was streaming).
    pub async fn unregister_event_sink(&self, client_id: u64) {
        let remaining = {
            let mut sinks = self.event_sinks.lock().await;
            sinks.remove(&client_id);
            sinks.len()
        };
        if remaining == 0 {
            // Last guest gone — stop host discovery and notify streams.
            self.scan.clear();
            let mut tasks = self.notify_tasks.lock().await;
            for (_, h) in tasks.drain() {
                h.abort();
            }
        }
    }

    /// Dispatch a request from IPC client `client`, tracking which client
    /// owns each LE link it opened.
    pub async fn handle_from(&self, client: u64, env: Envelope) -> Result<Option<Envelope>> {
        let kind = request_kind(&env);
        let resp = self.handle(env).await?;
        match kind {
            RequestKind::ConnectLe => {
                if let Some(dev) = resp.as_ref().and_then(connect_le_device_id) {
                    self.owned_links.lock().await.insert(dev, client);
                }
            }
            RequestKind::Disconnect(dev) => {
                self.owned_links.lock().await.remove(&dev.to_ascii_uppercase());
            }
            _ => {}
        }
        Ok(resp)
    }

    /// Client socket closed: drop the LE links it still owned (it can no
    /// longer drive them). Best effort, never fails the bridge.
    pub async fn release_client_links(&self, client: u64) {
        let devs = {
            let mut owned = self.owned_links.lock().await;
            let devs = links_owned_by(&owned, client);
            for d in &devs {
                owned.remove(d);
            }
            devs
        };
        for dev in devs {
            {
                let mut tasks = self.notify_tasks.lock().await;
                for k in notify_task_keys_for_device(tasks.keys(), &dev) {
                    if let Some(h) = tasks.remove(&k) {
                        h.abort();
                    }
                }
            }
            let r = tokio::time::timeout(
                std::time::Duration::from_secs(5),
                self.bluez.disconnect(&dev),
            )
            .await;
            info!(device_id = %dev, ok = matches!(r, Ok(Ok(()))),
                  "guest client gone: dropped its LE link");
            self.emit(event_envelope(event::Payload::ConnectionState(
                ConnectionStateEvent {
                    device_id: dev.clone(),
                    address: None,
                    state: ConnectionState::Disconnected as i32,
                    reason: "guest client gone".into(),
                },
            )))
            .await;
        }
    }

    /// Start (or restart) the link-loss watcher for `device_id`.
    ///
    /// 2026-11-19 (FP5 Tesla): the drop is logged with how long the link was
    /// up. A link that drops early (crate::linkpolicy) and that the guest has
    /// not started using gets one active reconnect; the guest keeps its
    /// pending link and is not told. Otherwise (or if the reconnect fails)
    /// the guest gets ConnectionState=Disconnected as before.
    async fn watch_link_loss(&self, device_id: &str) {
        let key = device_id.to_ascii_uppercase();
        let bluez = self.bluez.clone();
        let sinks = self.event_sinks.clone();
        let tasks = self.notify_tasks.clone();
        let watch = self.link_watch.clone();
        let dev = device_id.to_string();
        let key2 = key.clone();
        let threshold = crate::linkpolicy::early_drop_threshold(
            std::env::var(crate::linkpolicy::EARLY_DROP_ENV).ok().as_deref(),
        );
        let h = tokio::spawn(async move {
            let mut retried = false;
            loop {
                if let Err(e) = bluez.wait_link_lost(&dev).await {
                    warn!(error = %format!("{e:#}"), "link-loss watch failed; no disconnect forwarding for this link");
                    watch.lock().await.remove(&key2);
                    return;
                }
                let age = bluez.link_age(&dev).await;
                let streams = notify_task_keys_for_device(tasks.lock().await.keys(), &dev).len();
                let action = crate::linkpolicy::drop_action(
                    age.map(|a| a.0),
                    age.map(|a| a.1).unwrap_or(false),
                    streams,
                    retried,
                    threshold,
                );
                info!(device_id = %dev,
                      up_ms = age.map(|a| a.0.as_millis() as u64),
                      gatt_resolved = age.map(|a| a.1),
                      notify_streams = streams, retried, action = action.as_str(),
                      "LE link dropped");
                if action == crate::linkpolicy::DropAction::Reconnect {
                    retried = true;
                    let t0 = tokio::time::Instant::now();
                    match bluez
                        .connect_le(&dev, crate::linkpolicy::EARLY_RECONNECT_TIMEOUT_MS)
                        .await
                    {
                        Ok(_) => {
                            info!(device_id = %dev, after_ms = t0.elapsed().as_millis() as u64,
                                  "early drop: active reconnect ok, guest keeps its link");
                            continue;
                        }
                        Err(e) => {
                            info!(device_id = %dev, error = %format!("{e:#}"),
                                  after_ms = t0.elapsed().as_millis() as u64,
                                  "early drop: active reconnect failed");
                        }
                    }
                }
                info!(device_id = %dev, "LE link lost (BlueZ Connected=false): telling guest");
                {
                    let mut t = tasks.lock().await;
                    for k in notify_task_keys_for_device(t.keys(), &dev) {
                        if let Some(h) = t.remove(&k) {
                            h.abort();
                        }
                    }
                }
                let env = link_lost_event(&dev);
                let list: Vec<_> = sinks.lock().await.values().cloned().collect();
                for tx in list {
                    let _ = tx.send(env.clone()).await;
                }
                watch.lock().await.remove(&key2);
                return;
            }
        });
        if let Some(old) = self.link_watch.lock().await.insert(key, h) {
            old.abort();
        }
    }

    async fn emit(&self, env: Envelope) {
        let sinks: Vec<_> = self.event_sinks.lock().await.values().cloned().collect();
        for tx in sinks {
            let _ = tx.send(env.clone()).await;
        }
    }

    pub async fn handle(&self, env: Envelope) -> Result<Option<Envelope>> {
        let request_id = env.request_id;
        let body = match env.body {
            Some(envelope::Body::Request(r)) => r,
            Some(envelope::Body::Response(_)) | Some(envelope::Body::Event(_)) => {
                return Ok(Some(err_response(
                    request_id,
                    ErrorCode::InvalidArgument,
                    "expected request",
                )));
            }
            None => {
                return Ok(Some(err_response(
                    request_id,
                    ErrorCode::InvalidArgument,
                    "empty envelope",
                )));
            }
        };

        let op = match body.op {
            Some(op) => op,
            None => {
                return Ok(Some(err_response(
                    request_id,
                    ErrorCode::InvalidArgument,
                    "empty request",
                )));
            }
        };

        let resp = match op {
            request::Op::Ping(req) => {
                if is_keepalive_name(&req.client_name) {
                    debug!(client = %req.client_name, "ping");
                } else {
                    info!(client = %req.client_name, "ping");
                }
                ok_response(
                    request_id,
                    response::Result::Ping(PingResponse {
                        protocol_major: PROTOCOL_MAJOR,
                        protocol_minor: PROTOCOL_MINOR,
                        host_version: self.host_version.clone(),
                    }),
                )
            }
            request::Op::GetAdapterInfo(_) => match self.bluez.adapter_info().await {
                Ok(info) => ok_response(
                    request_id,
                    response::Result::GetAdapterInfo(
                        waydroid_bt_protocol::GetAdapterInfoResponse { info: Some(info) },
                    ),
                ),
                Err(e) => err_response(request_id, ErrorCode::Bluez, e.to_string()),
            },
            request::Op::SetPowered(req) => {
                let host_change = self
                    .bluez
                    .power_policy()
                    .set_guest_powered(req.powered, req.force_host);
                if let Some(powered) = host_change {
                    if let Err(e) = self.bluez.set_powered_host(powered).await {
                        return Ok(Some(err_response(
                            request_id,
                            ErrorCode::Bluez,
                            e.to_string(),
                        )));
                    }
                }
                match self.bluez.adapter_info().await {
                    Ok(info) => {
                        self.emit(event_envelope(event::Payload::AdapterState(
                            waydroid_bt_protocol::AdapterStateEvent {
                                info: Some(info.clone()),
                            },
                        )))
                        .await;
                        ok_response(
                            request_id,
                            response::Result::SetPowered(
                                waydroid_bt_protocol::SetPoweredResponse { info: Some(info) },
                            ),
                        )
                    }
                    Err(e) => err_response(request_id, ErrorCode::Bluez, e.to_string()),
                }
            }
            request::Op::StartLeScan(req) => {
                if self.bluez.power_policy().guest_soft_disabled() {
                    return Ok(Some(err_response(
                        request_id,
                        ErrorCode::SoftDisabled,
                        "guest Bluetooth soft-disabled",
                    )));
                }
                let id = self.scan.start(ScanSession {
                    service_uuids: req.service_uuids,
                    addresses: req.addresses,
                    active: req.active,
                });
                ok_response(
                    request_id,
                    response::Result::StartLeScan(waydroid_bt_protocol::StartLeScanResponse {
                        session_id: id,
                    }),
                )
            }
            request::Op::StopLeScan(req) => {
                if !self.scan.stop(req.session_id) {
                    return Ok(Some(err_response(
                        request_id,
                        ErrorCode::NotFound,
                        format!("unknown scan session {}", req.session_id),
                    )));
                }
                ok_response(
                    request_id,
                    response::Result::StopLeScan(waydroid_bt_protocol::StopLeScanResponse {}),
                )
            }
            request::Op::ConnectLe(req) => {
                if self.bluez.power_policy().guest_soft_disabled() {
                    return Ok(Some(err_response(
                        request_id,
                        ErrorCode::SoftDisabled,
                        "guest Bluetooth soft-disabled",
                    )));
                }
                let addr = match req.address.as_ref().map(|a| a.address.as_str()) {
                    Some(a) if !a.is_empty() => match normalize_bt_address(a) {
                        Some(n) => n,
                        None => {
                            return Ok(Some(err_response(
                                request_id,
                                ErrorCode::InvalidArgument,
                                "invalid address",
                            )));
                        }
                    },
                    _ => {
                        return Ok(Some(err_response(
                            request_id,
                            ErrorCode::InvalidArgument,
                            "address required",
                        )));
                    }
                };
                let address_msg = req.address.clone();
                let result = if req.wait_passive {
                    let proto_type = req.address.as_ref().map(|a| a.address_type).unwrap_or(0);
                    match self
                        .bluez
                        .connect_le_passive(&addr, proto_type, passive_wait(req.timeout_ms))
                        .await
                    {
                        Ok(v) => Ok(v),
                        Err(PassiveConnectError::Timeout) => {
                            return Ok(Some(err_response(
                                request_id,
                                ErrorCode::Timeout,
                                "passive wait timeout (peer not in range)",
                            )));
                        }
                        Err(PassiveConnectError::Unsupported(m)) => {
                            warn!(error = %m, "connect_le: passive auto-connect unavailable");
                            return Ok(Some(err_response(
                                request_id,
                                ErrorCode::Unsupported,
                                format!("passive auto-connect unavailable: {m}"),
                            )));
                        }
                        Err(PassiveConnectError::Other(e)) => Err(e),
                    }
                } else {
                    self.bluez.connect_le(&addr, req.timeout_ms).await
                };
                match result {
                    Ok((device_id, mtu)) => {
                        // Emit ConnectionState *after* queuing the response path:
                        // best-effort only — a broken secondary client must not
                        // prevent the ConnectLe response from being delivered.
                        let resp = ok_response(
                            request_id,
                            response::Result::ConnectLe(waydroid_bt_protocol::ConnectLeResponse {
                                device_id: device_id.clone(),
                                mtu,
                            }),
                        );
                        self.watch_link_loss(&device_id).await;
                        // Fire-and-forget connection state for any listeners.
                        let _ = self
                            .emit(event_envelope(event::Payload::ConnectionState(
                                ConnectionStateEvent {
                                    device_id,
                                    address: address_msg,
                                    state: ConnectionState::Connected as i32,
                                    reason: String::new(),
                                },
                            )))
                            .await;
                        resp
                    }
                    Err(e) => {
                        info!(error = %format!("{e:#}"), %addr, "connect_le failed");
                        err_response(request_id, ErrorCode::Bluez, format!("{e:#}"))
                    }
                }
            }
            request::Op::Disconnect(req) => {
                // Guest-initiated: it already knows; do not echo a "link lost".
                if let Some(h) = self
                    .link_watch
                    .lock()
                    .await
                    .remove(&req.device_id.to_ascii_uppercase())
                {
                    h.abort();
                }
                match self.bluez.disconnect(&req.device_id).await {
                Ok(()) => {
                    // Abort all notify streams for this device.
                    {
                        let mut tasks = self.notify_tasks.lock().await;
                        let keys = notify_task_keys_for_device(tasks.keys(), &req.device_id);
                        for k in keys {
                            if let Some(h) = tasks.remove(&k) {
                                h.abort();
                            }
                        }
                    }
                    self.emit(event_envelope(event::Payload::ConnectionState(
                        ConnectionStateEvent {
                            device_id: req.device_id.clone(),
                            address: None,
                            state: ConnectionState::Disconnected as i32,
                            reason: "guest disconnect".into(),
                        },
                    )))
                    .await;
                    ok_response(
                        request_id,
                        response::Result::Disconnect(waydroid_bt_protocol::DisconnectResponse {}),
                    )
                }
                Err(e) => err_response(request_id, ErrorCode::Bluez, e.to_string()),
                }
            }
            request::Op::GattDiscover(req) => match self.bluez.gatt_discover(&req.device_id).await {
                Ok(services) => ok_response(
                    request_id,
                    response::Result::GattDiscover(waydroid_bt_protocol::GattDiscoverResponse {
                        services,
                    }),
                ),
                Err(e) => err_response(request_id, ErrorCode::Bluez, e.to_string()),
            },
            request::Op::GattRead(req) => {
                let svc = if req.service_uuid.is_empty() {
                    None
                } else {
                    Some(req.service_uuid.as_str())
                };
                match self
                    .bluez
                    .gatt_read(&req.device_id, svc, &req.characteristic_uuid)
                    .await
                {
                    Ok(value) => ok_response(
                        request_id,
                        response::Result::GattRead(GattReadResponse {
                            value: Bytes::from(value),
                        }),
                    ),
                    Err(e) => err_response(request_id, ErrorCode::Bluez, e.to_string()),
                }
            }
            request::Op::GattWrite(req) => {
                let svc = if req.service_uuid.is_empty() {
                    None
                } else {
                    Some(req.service_uuid.as_str())
                };
                match self
                    .bluez
                    .gatt_write(
                        &req.device_id,
                        svc,
                        &req.characteristic_uuid,
                        &req.value,
                        req.without_response,
                    )
                    .await
                {
                    Ok(()) => {
                        info!(device_id = %req.device_id, char_uuid = %req.characteristic_uuid,
                              len = req.value.len(), without_response = req.without_response,
                              "gatt write ok");
                        ok_response(
                            request_id,
                            response::Result::GattWrite(waydroid_bt_protocol::GattWriteResponse {}),
                        )
                    }
                    Err(e) => {
                        warn!(device_id = %req.device_id, char_uuid = %req.characteristic_uuid,
                              len = req.value.len(), error = %e, "gatt write failed");
                        err_response(request_id, ErrorCode::Bluez, e.to_string())
                    }
                }
            }
            request::Op::GattSetNotify(req) => {
                let key = format!(
                    "{}:{}:{}",
                    req.device_id, req.service_uuid, req.characteristic_uuid
                );
                if !req.enable {
                    if let Some(h) = self.notify_tasks.lock().await.remove(&key) {
                        h.abort();
                    }
                    return Ok(Some(ok_response(
                        request_id,
                        response::Result::GattSetNotify(
                            waydroid_bt_protocol::GattSetNotifyResponse {},
                        ),
                    )));
                }
                // Re-enable must abort any prior stream for this key (insert alone
                // would drop the JoinHandle without abort → duplicate BlueZ notifies).
                if let Some(h) = self.notify_tasks.lock().await.remove(&key) {
                    h.abort();
                }
                let svc = if req.service_uuid.is_empty() {
                    None
                } else {
                    Some(req.service_uuid.clone())
                };
                let device_id = req.device_id.clone();
                let char_uuid = req.characteristic_uuid.clone();
                let service_uuid = req.service_uuid.clone();
                match self
                    .bluez
                    .gatt_notify_stream(&device_id, svc.as_deref(), &char_uuid)
                    .await
                {
                    Ok(stream) => {
                        // Fan-out to guest clients present at enable time (scan + ATT).
                        // Soft HCI multi-link workers filter by device_id so peer A
                        // never applies peer B's notifications.
                        let sinks: Vec<_> =
                            self.event_sinks.lock().await.values().cloned().collect();
                        info!(
                            %device_id,
                            %char_uuid,
                            clients = sinks.len(),
                            "gatt set_notify stream started"
                        );
                        let handle = tokio::spawn(async move {
                            futures::pin_mut!(stream);
                            let mut n: u64 = 0;
                            while let Some(value) = stream.next().await {
                                n += 1;
                                // Low-rate GATT (e.g. Tesla VCSEC) logs every value;
                                // high-rate sensors log the first few then every 200th.
                                if n <= 20 || n % 200 == 0 {
                                    info!(%device_id, %char_uuid, n, len = value.len(),
                                          "gatt inbound value");
                                }
                                let env = event_envelope(event::Payload::GattNotification(
                                    GattNotificationEvent {
                                        device_id: device_id.clone(),
                                        characteristic_uuid: char_uuid.clone(),
                                        service_uuid: service_uuid.clone(),
                                        value: Bytes::from(value),
                                    },
                                ));
                                if sinks.is_empty() {
                                    break;
                                }
                                let mut any_ok = false;
                                for tx in &sinks {
                                    if tx.send(env.clone()).await.is_ok() {
                                        any_ok = true;
                                    }
                                }
                                if !any_ok {
                                    break;
                                }
                            }
                        });
                        self.notify_tasks.lock().await.insert(key, handle);
                        ok_response(
                            request_id,
                            response::Result::GattSetNotify(
                                waydroid_bt_protocol::GattSetNotifyResponse {},
                            ),
                        )
                    }
                    Err(e) => err_response(request_id, ErrorCode::Bluez, e.to_string()),
                }
            }
            request::Op::CreateBond(req) => {
                let addr = match req.address.as_ref().map(|a| a.address.as_str()) {
                    Some(a) if !a.is_empty() => match normalize_bt_address(a) {
                        Some(n) => n,
                        None => {
                            return Ok(Some(err_response(
                                request_id,
                                ErrorCode::InvalidArgument,
                                "invalid address",
                            )));
                        }
                    },
                    _ => {
                        return Ok(Some(err_response(
                            request_id,
                            ErrorCode::InvalidArgument,
                            "address required",
                        )));
                    }
                };
                match self.bluez.create_bond(&addr).await {
                    Ok(state) => {
                        self.emit(event_envelope(event::Payload::BondState(
                            waydroid_bt_protocol::BondStateEvent {
                                address: req.address.clone(),
                                state: state as i32,
                            },
                        )))
                        .await;
                        ok_response(
                            request_id,
                            response::Result::CreateBond(waydroid_bt_protocol::CreateBondResponse {
                                state: state as i32,
                            }),
                        )
                    }
                    Err(e) => err_response(request_id, ErrorCode::Bluez, e.to_string()),
                }
            }
            request::Op::RemoveBond(req) => {
                let addr = match req.address.as_ref().map(|a| a.address.as_str()) {
                    Some(a) if !a.is_empty() => a.to_string(),
                    _ => {
                        return Ok(Some(err_response(
                            request_id,
                            ErrorCode::InvalidArgument,
                            "address required",
                        )));
                    }
                };
                match self.bluez.remove_bond(&addr).await {
                    Ok(()) => ok_response(
                        request_id,
                        response::Result::RemoveBond(waydroid_bt_protocol::RemoveBondResponse {}),
                    ),
                    Err(e) => err_response(request_id, ErrorCode::Bluez, e.to_string()),
                }
            }
            request::Op::ListBonds(_) => match self.bluez.list_bonds().await {
                Ok(devices) => ok_response(
                    request_id,
                    response::Result::ListBonds(waydroid_bt_protocol::ListBondsResponse {
                        devices,
                    }),
                ),
                Err(e) => err_response(request_id, ErrorCode::Bluez, e.to_string()),
            },
        };

        Ok(Some(resp))
    }

    /// Forward advertisement snapshots as AdvReport events.
    pub async fn emit_adv(&self, session_id: u32, snap: crate::bluez::AdvSnapshot) {
        let env = event_envelope(event::Payload::AdvReport(AdvReportEvent {
            session_id,
            address: Some(BtAddress {
                address: snap.address,
                address_type: snap.address_type as i32,
            }),
            rssi: snap.rssi,
            name: snap.name,
            connectable: snap.connectable,
            manufacturer_data: Bytes::from(snap.manufacturer_data),
            service_data: snap
                .service_data
                .into_iter()
                .map(|(k, v)| (k, Bytes::from(v)))
                .collect(),
            service_uuids: snap.service_uuids,
            raw_adv: Bytes::new(),
        }));
        self.emit(env).await;
    }
}

/// Normalize a Bluetooth address to uppercase `AA:BB:CC:DD:EE:FF`.
/// Accepts lower/mixed case and optional whitespace; rejects empty / wrong shape.
/// Notify task map keys are `{device_id}:{service}:{char}`. Select keys to abort
/// when a device disconnects (pure helper — unit tested).
pub(crate) fn notify_task_keys_for_device<'a>(
    keys: impl IntoIterator<Item = &'a String>,
    device_id: &str,
) -> Vec<String> {
    let prefix = format!("{device_id}:");
    let id_upper = device_id.to_ascii_uppercase();
    keys.into_iter()
        .filter(|k| {
            k.starts_with(&prefix)
                || k.to_ascii_uppercase().starts_with(&format!("{id_upper}:"))
                || k.eq_ignore_ascii_case(device_id)
        })
        .cloned()
        .collect()
}

pub(crate) fn normalize_bt_address(raw: &str) -> Option<String> {
    let s = raw.trim().to_uppercase();
    if s.is_empty() {
        return None;
    }
    // Allow AA:BB:CC:DD:EE:FF (17 chars) or AABBCCDDEEFF (12 hex)
    let hex: String = s.chars().filter(|c| c.is_ascii_hexdigit()).collect();
    if hex.len() != 12 {
        return None;
    }
    if !hex.chars().all(|c| c.is_ascii_hexdigit()) {
        return None;
    }
    let bytes: Vec<&str> = (0..6).map(|i| &hex[i * 2..i * 2 + 2]).collect();
    Some(bytes.join(":"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn normalize_bt_address_uppercases_and_formats() {
        assert_eq!(
            normalize_bt_address("e3:e4:f3:2a:0d:f0").as_deref(),
            Some("E3:E4:F3:2A:0D:F0")
        );
        assert_eq!(
            normalize_bt_address("  EC:83:50:BF:75:89  ").as_deref(),
            Some("EC:83:50:BF:75:89")
        );
        assert_eq!(
            normalize_bt_address("aabbccddeeff").as_deref(),
            Some("AA:BB:CC:DD:EE:FF")
        );
    }

    #[test]
    fn normalize_bt_address_rejects_bad() {
        assert!(normalize_bt_address("").is_none());
        assert!(normalize_bt_address("   ").is_none());
        assert!(normalize_bt_address("not-a-mac").is_none());
        assert!(normalize_bt_address("AA:BB:CC:DD:EE").is_none());
        assert!(normalize_bt_address("GG:HH:II:JJ:KK:LL").is_none());
    }

    fn ping_env(name: &str) -> Envelope {
        Envelope {
            request_id: 1,
            body: Some(envelope::Body::Request(waydroid_bt_protocol::Request {
                op: Some(request::Op::Ping(waydroid_bt_protocol::PingRequest {
                    client_name: name.into(),
                })),
            })),
        }
    }

    #[test]
    fn request_kind_classifies() {
        assert_eq!(
            request_kind(&ping_env("soft-hci-keepalive")),
            RequestKind::Ping("soft-hci-keepalive".into())
        );
        assert!(is_keepalive_name("soft-hci-keepalive"));
        assert!(!is_keepalive_name("waydroid-bt-ping"));
        let dc = Envelope {
            request_id: 2,
            body: Some(envelope::Body::Request(waydroid_bt_protocol::Request {
                op: Some(request::Op::Disconnect(waydroid_bt_protocol::DisconnectRequest {
                    device_id: "aa:bb:cc:dd:ee:01".into(),
                })),
            })),
        };
        assert_eq!(request_kind(&dc), RequestKind::Disconnect("aa:bb:cc:dd:ee:01".into()));
        let empty = Envelope { request_id: 3, body: None };
        assert_eq!(request_kind(&empty), RequestKind::Other);
    }

    fn connect_env(wait_passive: bool) -> Envelope {
        Envelope {
            request_id: 4,
            body: Some(envelope::Body::Request(waydroid_bt_protocol::Request {
                op: Some(request::Op::ConnectLe(waydroid_bt_protocol::ConnectLeRequest {
                    address: Some(BtAddress {
                        address: "AA:BB:CC:DD:EE:01".into(),
                        address_type: 1,
                    }),
                    timeout_ms: 0,
                    wait_passive,
                })),
            })),
        }
    }

    #[test]
    fn passive_connect_is_detected() {
        assert!(is_passive_connect(&connect_env(true)));
        assert!(!is_passive_connect(&connect_env(false)));
        assert!(!is_passive_connect(&ping_env("soft-hci-keepalive")));
        assert_eq!(request_kind(&connect_env(true)), RequestKind::ConnectLe);
    }

    #[test]
    fn passive_wait_default_and_cap() {
        assert_eq!(passive_wait(0), Duration::from_millis(PASSIVE_WAIT_DEFAULT_MS as u64));
        assert_eq!(passive_wait(90_000), Duration::from_secs(90));
        assert_eq!(passive_wait(u32::MAX), Duration::from_millis(PASSIVE_WAIT_MAX_MS as u64));
    }

    #[test]
    fn connect_le_device_id_only_on_success() {
        let ok = ok_response(
            7,
            response::Result::ConnectLe(waydroid_bt_protocol::ConnectLeResponse {
                device_id: "aa:bb:cc:dd:ee:01".into(),
                mtu: 23,
            }),
        );
        assert_eq!(connect_le_device_id(&ok).as_deref(), Some("AA:BB:CC:DD:EE:01"));
        let err = err_response(7, ErrorCode::Bluez, "device not found after 12.0s scan");
        assert_eq!(connect_le_device_id(&err), None);
    }

    #[test]
    fn links_owned_by_filters_client() {
        let mut m = HashMap::new();
        m.insert("AA:BB:CC:DD:EE:02".to_string(), 5u64);
        m.insert("AA:BB:CC:DD:EE:01".to_string(), 5u64);
        m.insert("AA:BB:CC:DD:EE:03".to_string(), 6u64);
        assert_eq!(
            links_owned_by(&m, 5),
            vec!["AA:BB:CC:DD:EE:01".to_string(), "AA:BB:CC:DD:EE:02".to_string()]
        );
        assert!(links_owned_by(&m, 9).is_empty());
    }

    #[test]
    fn link_lost_event_is_disconnected() {
        let e = link_lost_event("AA:BB:CC:DD:EE:01");
        match e.body {
            Some(envelope::Body::Event(ev)) => match ev.payload {
                Some(event::Payload::ConnectionState(c)) => {
                    assert_eq!(c.device_id, "AA:BB:CC:DD:EE:01");
                    assert_eq!(c.state, ConnectionState::Disconnected as i32);
                    assert_eq!(c.reason, "link lost");
                }
                _ => panic!("not a connection state"),
            },
            _ => panic!("not an event"),
        }
    }

    #[test]
    fn notify_task_keys_for_device_selects_prefix_only() {
        let keys = vec![
            "AA:BB:CC:DD:EE:01:svc:char".to_string(),
            "AA:BB:CC:DD:EE:02:svc:char".to_string(),
            "aa:bb:cc:dd:ee:01:other:x".to_string(),
            "ZZ:ZZ:ZZ:ZZ:ZZ:ZZ:s:c".to_string(),
        ];
        let got = notify_task_keys_for_device(keys.iter(), "AA:BB:CC:DD:EE:01");
        assert_eq!(got.len(), 2);
        assert!(got.iter().all(|k| k.to_ascii_uppercase().starts_with("AA:BB:CC:DD:EE:01:")));
    }
}

