//! Request dispatch: protocol ops → BlueZ + policy.

use std::collections::HashMap;
use std::sync::Arc;

use anyhow::Result;
use bytes::Bytes;
use futures::StreamExt;
use tokio::sync::{mpsc, Mutex};
use tracing::{info, warn};
use waydroid_bt_protocol::{
    envelope, err_response, event, event_envelope, ok_response, request, response, AdvReportEvent,
    BtAddress, ConnectionState, ConnectionStateEvent, Envelope, ErrorCode, GattNotificationEvent,
    GattReadResponse, PingResponse, PROTOCOL_MAJOR, PROTOCOL_MINOR,
};

use crate::bluez::BlueZ;
use crate::policy::{ScanPolicy, ScanSession};

pub struct BridgeService {
    bluez: BlueZ,
    scan: Arc<ScanPolicy>,
    /// Multi-client event sinks (scan + ATT may be connected at once).
    /// Keyed by monotonic client id so disconnect of one client does not
    /// steal or abort another client's notify stream.
    event_sinks: Mutex<HashMap<u64, mpsc::Sender<Envelope>>>,
    next_client_id: std::sync::atomic::AtomicU64,
    /// Active notify tasks keyed by device_id + char uuid
    notify_tasks: Mutex<HashMap<String, tokio::task::JoinHandle<()>>>,
    host_version: String,
}

impl BridgeService {
    pub fn new(bluez: BlueZ, scan: Arc<ScanPolicy>, host_version: String) -> Self {
        Self {
            bluez,
            scan,
            event_sinks: Mutex::new(HashMap::new()),
            next_client_id: std::sync::atomic::AtomicU64::new(1),
            notify_tasks: Mutex::new(HashMap::new()),
            host_version,
        }
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
                info!(client = %req.client_name, "ping");
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
                match self.bluez.connect_le(&addr, req.timeout_ms).await {
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
                        info!(error = %e, %addr, "connect_le failed");
                        err_response(request_id, ErrorCode::Bluez, e.to_string())
                    }
                }
            }
            request::Op::Disconnect(req) => match self.bluez.disconnect(&req.device_id).await {
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
            },
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

