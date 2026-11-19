//! BlueZ access via bluer (official Rust bindings).

pub mod mgmt;

use std::collections::HashMap;
use std::sync::Arc;
use std::time::Duration;

use anyhow::{anyhow, Context, Result};
use bluer::agent::{Agent, AgentHandle};
use bluer::gatt::remote::{Characteristic, Service};
use bluer::{Adapter, AdapterEvent, Address, AddressType, Device, DiscoveryTransport, Session};
use futures::{pin_mut, StreamExt};
use tokio::sync::{broadcast, Mutex, RwLock};
use tracing::{debug, info, warn};
use waydroid_bt_protocol::{
    AdapterInfo, AdapterState, AddressType as ProtoAddressType, BondState, BondedDevice, BtAddress,
    GattCharacteristic, GattDescriptor, GattService,
};

use crate::discovery::{
    connect_retry_delay, connect_scan_budget_from, connect_scan_transport,
    guest_pair_discovery_transport, is_retryable_connect_error, peer_presence,
    DiscoveryTransportName, PeerPresence, CONNECT_SCAN_SECS_ENV,
};
use crate::policy::{PowerPolicy, ScanPolicy};

/// Re-check interval while waiting passively (missed D-Bus signal safety
/// net; a D-Bus property read, not a scan).
const PASSIVE_RECHECK: Duration = Duration::from_secs(30);
/// After a kernel auto-connect, wait at most this long for GATT to resolve
/// before taking the peer off the auto-connect list.
const SERVICES_RESOLVED_WAIT: Duration = Duration::from_secs(10);

#[derive(Debug, thiserror::Error)]
pub enum PassiveConnectError {
    /// No kernel mgmt access: caller should fall back to active connects.
    #[error("passive auto-connect unsupported: {0}")]
    Unsupported(String),
    /// Peer did not show up within the wait (normal: car not in range).
    #[error("passive wait timeout")]
    Timeout,
    #[error("{0:#}")]
    Other(anyhow::Error),
}

#[derive(Clone)]
pub struct BlueZ {
    inner: Arc<BlueZInner>,
}

struct BlueZInner {
    session: Session,
    /// Leave the host adapter non-pairable while no guest bond is running.
    idle_pairable_off: bool,
    /// Serialises guest CreateBond so the pairing window cannot overlap.
    bond_lock: Mutex<()>,
    adapter: RwLock<Option<Adapter>>,
    power: PowerPolicy,
    /// device_id (address string) -> open device handle
    devices: Mutex<HashMap<String, Device>>,
    /// device_id -> (when the LE link came up, GATT resolved since) for
    /// drop-timing logs and the early-drop policy (crate::linkpolicy).
    link_up: Mutex<HashMap<String, (tokio::time::Instant, bool)>>,
    /// "Kick": wake every pending passive wait and try one active connect
    /// (SIGUSR1 from tesla-frunk-root.sh when the Frunk tile is pressed).
    kick: tokio::sync::Notify,
    /// Number of passive waits currently armed (for the kick log line).
    passive_pending: std::sync::atomic::AtomicUsize,
    #[allow(dead_code)]
    adapter_events: broadcast::Sender<AdapterInfo>,
}

async fn set_pairable_logged(adapter: &Adapter, on: bool, why: &str) {
    match adapter.set_pairable(on).await {
        Ok(()) => info!(pairable = on, reason = why, "host adapter Pairable set"),
        Err(e) => {
            warn!(pairable = on, reason = why, error = %e, "could not set host adapter Pairable")
        }
    }
}

fn bluer_transport(name: DiscoveryTransportName) -> DiscoveryTransport {
    match name {
        DiscoveryTransportName::Le => DiscoveryTransport::Le,
        DiscoveryTransportName::BrEdr => DiscoveryTransport::BrEdr,
        DiscoveryTransportName::Auto => DiscoveryTransport::Auto,
    }
}

impl BlueZ {
    pub async fn connect(power: PowerPolicy, idle_pairable_off: bool) -> Result<Self> {
        let session = Session::new()
            .await
            .context("connect to BlueZ session (is bluetoothd running?)")?;
        // No permanent or default agent. Registering a NoInputNoOutput agent
        // as BlueZ's default would push the desktop agent (Phosh, GNOME, ...)
        // aside and make the host accept Just-Works pairing from anyone in
        // range. A non-default agent is registered only for the duration of a
        // guest CreateBond (see create_bond).
        info!("BlueZ pairing agent: on-demand only, never default");

        let adapter = session
            .default_adapter()
            .await
            .context("no default Bluetooth adapter")?;
        let adapter_name = adapter.name().to_string();
        info!(adapter = %adapter_name, "BlueZ adapter opened");
        if idle_pairable_off {
            set_pairable_logged(&adapter, false, "idle").await;
        }

        let (tx, _) = broadcast::channel(64);
        Ok(Self {
            inner: Arc::new(BlueZInner {
                session,
                idle_pairable_off,
                bond_lock: Mutex::new(()),
                adapter: RwLock::new(Some(adapter)),
                power,
                devices: Mutex::new(HashMap::new()),
                link_up: Mutex::new(HashMap::new()),
                kick: tokio::sync::Notify::new(),
                passive_pending: std::sync::atomic::AtomicUsize::new(0),
                adapter_events: tx,
            }),
        })
    }

    pub fn power_policy(&self) -> &PowerPolicy {
        &self.inner.power
    }

    #[allow(dead_code)]
    pub fn subscribe_adapter_events(&self) -> broadcast::Receiver<AdapterInfo> {
        self.inner.adapter_events.subscribe()
    }

    pub(crate) async fn adapter(&self) -> Result<Adapter> {
        self.inner
            .adapter
            .read()
            .await
            .clone()
            .ok_or_else(|| anyhow!("adapter unavailable"))
    }

    pub async fn adapter_info(&self) -> Result<AdapterInfo> {
        let adapter = match self.adapter().await {
            Ok(a) => a,
            Err(_) => {
                return Ok(AdapterInfo {
                    address: None,
                    name: String::new(),
                    alias: String::new(),
                    state: AdapterState::Unavailable as i32,
                    powered: false,
                    le_supported: false,
                    guest_soft_disabled: self.inner.power.guest_soft_disabled(),
                    uuids: vec![],
                });
            }
        };

        let address = adapter.address().await.unwrap_or(Address::any());
        let name = adapter.system_name().await.unwrap_or_default();
        let alias = adapter.alias().await.unwrap_or_default();
        let powered = adapter.is_powered().await.unwrap_or(false);
        let uuids = adapter
            .uuids()
            .await
            .ok()
            .flatten()
            .map(|s| s.into_iter().map(|u| u.to_string()).collect())
            .unwrap_or_default();

        let le_supported = true;
        let state = if powered {
            AdapterState::On
        } else {
            AdapterState::Off
        };

        // Guest soft-disabled: report powered=false / OFF to guest without
        // changing host radio.
        let guest_soft = self.inner.power.guest_soft_disabled();
        let (guest_powered, guest_state) = if guest_soft {
            (false, AdapterState::Off)
        } else {
            (powered, state)
        };

        Ok(AdapterInfo {
            address: Some(BtAddress {
                address: address.to_string(),
                address_type: ProtoAddressType::Public as i32,
            }),
            name,
            alias,
            state: guest_state as i32,
            powered: guest_powered,
            le_supported,
            guest_soft_disabled: guest_soft,
            uuids,
        })
    }

    #[allow(dead_code)]
    pub async fn publish_adapter_state(&self) {
        if let Ok(info) = self.adapter_info().await {
            let _ = self.inner.adapter_events.send(info);
        }
    }

    pub async fn set_powered_host(&self, powered: bool) -> Result<AdapterInfo> {
        let adapter = self.adapter().await?;
        adapter
            .set_powered(powered)
            .await
            .context("set_powered on BlueZ adapter")?;
        self.adapter_info().await
    }

    pub async fn open_discovery_stream(
        &self,
    ) -> Result<impl futures::Stream<Item = AdapterEvent> + Unpin> {
        let adapter = self.adapter().await?;
        if !adapter.is_powered().await.unwrap_or(false) {
            return Err(anyhow!("adapter not powered"));
        }
        // Dual (auto): BR/EDR inquiry + LE so guest Settings Inquiry can see
        // classic devices (e.g. Xbox) while LE (Hue) still works.
        let transport_name = guest_pair_discovery_transport();
        let filter = bluer::DiscoveryFilter {
            transport: bluer_transport(transport_name),
            ..Default::default()
        };
        info!(
            transport = transport_name.as_bluez_str(),
            classic = transport_name.includes_classic(),
            le = transport_name.includes_le(),
            "setting discovery filter for guest pair scan"
        );
        adapter
            .set_discovery_filter(filter)
            .await
            .context("set discovery filter")?;
        // with_changes re-emits DeviceAdded on RSSI/name updates so Soft HCI keeps
        // getting AdvReports for already-known devices (PRS after GATT probe, etc.).
        let stream = adapter
            .discover_devices_with_changes()
            .await
            .context("discover_devices_with_changes")?;
        Ok(stream)
    }

    pub async fn device_for_address(&self, address: &str) -> Result<Device> {
        let adapter = self.adapter().await?;
        let addr: Address = address
            .parse()
            .map_err(|e| anyhow!("invalid address {address}: {e}"))?;
        let device = adapter.device(addr).context("adapter.device")?;
        Ok(device)
    }

    /// Wake all pending passive waits for one active connect attempt each.
    /// Returns how many passive waits were pending.
    pub fn kick(&self) -> usize {
        let n = self
            .inner
            .passive_pending
            .load(std::sync::atomic::Ordering::SeqCst);
        self.inner.kick.notify_waiters();
        n
    }

    async fn mark_link_up(&self, id: &str) {
        self.inner
            .link_up
            .lock()
            .await
            .insert(id.to_uppercase(), (tokio::time::Instant::now(), false));
    }

    async fn mark_resolved(&self, id: &str) {
        if let Some(e) = self.inner.link_up.lock().await.get_mut(&id.to_uppercase()) {
            e.1 = true;
        }
    }

    /// (how long the link has been / was up, GATT resolved) for `id`.
    pub async fn link_age(&self, id: &str) -> Option<(Duration, bool)> {
        self.inner
            .link_up
            .lock()
            .await
            .get(&id.to_uppercase())
            .map(|(t, r)| (t.elapsed(), *r))
    }

    /// One active connect attempt for a peer we are passively waiting for
    /// (kick). Short scan, then Device1.Connect with a bounded timeout; a
    /// timed-out Connect is cancelled like in connect_le.
    async fn kick_connect(&self, adapter: &Adapter, want: Address, address: &str) {
        let started = tokio::time::Instant::now();
        if self.connected_device(adapter, want).await.is_some() {
            return;
        }
        if let Err(e) = self.ensure_device_known(address, Duration::from_secs(6)).await {
            info!(error = %format!("{e:#}"), "kick: car not found in scan");
            return;
        }
        let dev = match adapter.device(want) {
            Ok(d) => d,
            Err(e) => {
                info!(error = %e, "kick: no device object");
                return;
            }
        };
        match tokio::time::timeout(Duration::from_secs(8), dev.connect()).await {
            Ok(Ok(())) => info!(after_ms = started.elapsed().as_millis() as u64,
                                "kick: active connect ok"),
            Ok(Err(e)) => info!(error = %e, after_ms = started.elapsed().as_millis() as u64,
                                "kick: active connect failed"),
            Err(_) => {
                let _ = tokio::time::timeout(Duration::from_secs(3), dev.disconnect()).await;
                info!("kick: active connect timed out (cancelled)");
            }
        }
    }

    pub async fn connect_le(&self, address: &str, timeout_ms: u32) -> Result<(String, u32)> {
        let timeout = if timeout_ms == 0 {
            Duration::from_secs(30)
        } else {
            Duration::from_millis(timeout_ms as u64)
        };
        // One overall deadline for scan + every Connect attempt, so the guest
        // always gets its answer within the timeout it asked for (before the
        // Android stack gives up on its side). A missing car is a normal,
        // quick failure; the guest HAL keeps the connection pending and asks
        // again later, like a real controller would.
        let deadline = tokio::time::Instant::now() + timeout;
        let scan_budget = connect_scan_budget_from(
            timeout,
            std::env::var(CONNECT_SCAN_SECS_ENV).ok().as_deref(),
        );

        // Make sure BlueZ has a live Device object for the peer. Background
        // reconnects (e.g. Tesla phone key) arrive with no guest scan running,
        // so the temporary device object has usually expired: scan for it first.
        self.ensure_device_known(address, scan_budget).await?;

        let device = self.device_for_address(address).await?;
        let id = address.to_uppercase();
        let mut retries: u32 = 0;
        loop {
            // Already connected (guest reconnect / race after Soft HCI teardown): reuse.
            if device.is_connected().await.unwrap_or(false) {
                self.inner.devices.lock().await.insert(id.clone(), device);
                info!(%id, "LE device already connected — reuse");
                if self.link_age(&id).await.is_none() {
                    self.mark_link_up(&id).await;
                }
                return Ok((id, 23u32));
            }
            let left = deadline.saturating_duration_since(tokio::time::Instant::now());
            if left < Duration::from_millis(500) {
                return Err(anyhow!("connect timeout (no time left after scan)"));
            }
            debug!(%address, left_ms = left.as_millis() as u64, "connecting LE device");
            match tokio::time::timeout(left, device.connect()).await {
                Err(_) => {
                    // BlueZ keeps a timed-out Connect pending in the kernel;
                    // the next attempt then aborts at once
                    // (le-connection-abort-by-local). Cancel it explicitly.
                    let cancel =
                        tokio::time::timeout(Duration::from_secs(3), device.disconnect()).await;
                    info!(%address, cancelled = matches!(cancel, Ok(Ok(()))),
                          "connect_le: timed out, pending BlueZ connect cancelled");
                    return Err(anyhow!("connect timeout"));
                }
                Ok(Ok(())) => break,
                Ok(Err(e)) => {
                    let msg = e.to_string();
                    let left = deadline.saturating_duration_since(tokio::time::Instant::now());
                    match connect_retry_delay(is_retryable_connect_error(&msg), retries, left) {
                        Some(pause) => {
                            retries += 1;
                            warn!(%address, error = %msg, retry = retries,
                                  "connect_le: connect failed, rescanning and retrying");
                            tokio::time::sleep(pause).await;
                            let left =
                                deadline.saturating_duration_since(tokio::time::Instant::now());
                            self.ensure_device_known(address, scan_budget.min(left / 2))
                                .await?;
                            continue;
                        }
                        None => return Err(anyhow!("device.connect: {msg}")),
                    }
                }
            }
        }

        self.inner.devices.lock().await.insert(id.clone(), device);
        self.mark_link_up(&id).await;
        // MTU not always exposed via D-Bus; common LE default.
        let mtu = 23u32;
        info!(%id, mtu, retries, "LE device connected");
        Ok((id, mtu))
    }

    /// Passive background connect ("car absent is normal").
    ///
    /// Instead of scanning actively, put the peer on the kernel LE
    /// auto-connect list and wait up to `wait` for the kernel to connect it
    /// (low-duty passive scan with the controller Filter Accept List, like an
    /// Android controller does for `autoConnect`). The arm is removed again
    /// when the link is up, on timeout, and when this future is dropped (the
    /// guest cancelled and closed its socket).
    pub async fn connect_le_passive(
        &self,
        address: &str,
        proto_address_type: i32,
        wait: Duration,
    ) -> std::result::Result<(String, u32), PassiveConnectError> {
        let want: Address = address
            .parse()
            .map_err(|e| PassiveConnectError::Other(anyhow!("invalid address {address}: {e}")))?;
        let addr_le = mgmt::parse_bdaddr_le(address)
            .ok_or_else(|| PassiveConnectError::Other(anyhow!("invalid address")))?;
        let adapter = self.adapter().await.map_err(PassiveConnectError::Other)?;
        let index = mgmt::hci_index_from_name(adapter.name())
            .ok_or_else(|| PassiveConnectError::Unsupported("adapter index".into()))?;
        let id = address.to_uppercase();

        if let Some(dev) = self.connected_device(&adapter, want).await {
            self.inner.devices.lock().await.insert(id.clone(), dev);
            info!(%id, "LE device already connected — reuse");
            if self.link_age(&id).await.is_none() {
                self.mark_link_up(&id).await;
            }
            return Ok((id, 23u32));
        }

        // Adapter events first, so a connect right after arming is not missed.
        let mut adapter_events = Box::pin(
            adapter
                .events()
                .await
                .map_err(|e| PassiveConnectError::Other(anyhow!("adapter events: {e}")))?,
        );
        let addr_type = mgmt::mgmt_le_addr_type(proto_address_type);
        let mut arm = tokio::task::spawn_blocking(move || {
            mgmt::AutoConnectArm::arm(index, addr_le, addr_type)
        })
        .await
        .map_err(|e| PassiveConnectError::Other(anyhow!("join: {e}")))?
        .map_err(|e| match e {
            mgmt::MgmtError::Unavailable(m) => PassiveConnectError::Unsupported(m),
            other => PassiveConnectError::Other(anyhow!("{other}")),
        })?;
        info!(%address, wait_s = wait.as_secs(),
              "connect_le: passive wait (kernel LE auto-connect armed, no active scan)");

        let started = tokio::time::Instant::now();
        let deadline = started + wait;
        struct Pending<'a>(&'a std::sync::atomic::AtomicUsize);
        impl Drop for Pending<'_> {
            fn drop(&mut self) {
                self.0.fetch_sub(1, std::sync::atomic::Ordering::SeqCst);
            }
        }
        self.inner
            .passive_pending
            .fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        let _pending = Pending(&self.inner.passive_pending);
        let connected = loop {
            if let Some(dev) = self.connected_device(&adapter, want).await {
                break dev;
            }
            // Device events for the existing object (Connected flips there).
            let mut dev_events = match adapter.device(want) {
                Ok(d) if adapter
                    .device_addresses()
                    .await
                    .map(|v| v.contains(&want))
                    .unwrap_or(false) =>
                {
                    d.events().await.ok().map(Box::pin)
                }
                _ => None,
            };
            if let Some(dev) = self.connected_device(&adapter, want).await {
                break dev;
            }
            let dev_ev = async {
                match dev_events.as_mut() {
                    Some(s) => loop {
                        match s.next().await {
                            Some(bluer::DeviceEvent::PropertyChanged(
                                bluer::DeviceProperty::Connected(true),
                            )) => return,
                            Some(_) => continue,
                            None => futures::future::pending::<()>().await,
                        }
                    },
                    None => futures::future::pending::<()>().await,
                }
            };
            let ad_ev = async {
                loop {
                    match adapter_events.next().await {
                        Some(AdapterEvent::DeviceAdded(a)) if a == want => return,
                        Some(_) => continue,
                        None => futures::future::pending::<()>().await,
                    }
                }
            };
            tokio::select! {
                _ = tokio::time::sleep_until(deadline) => {
                    arm.disarm();
                    debug!(%address, "connect_le: passive wait timed out (peer absent)");
                    return Err(PassiveConnectError::Timeout);
                }
                _ = dev_ev => {}
                _ = ad_ev => {}
                // Frunk tile pressed: one active connect, stay armed.
                _ = self.inner.kick.notified() => {
                    info!("kick: active connect requested during passive wait");
                    self.kick_connect(&adapter, want, address).await;
                }
                // Safety net only (missed signal); not a scan.
                _ = tokio::time::sleep(PASSIVE_RECHECK) => {}
            }
        };
        // Hand the link to the guest AT ONCE (19 Nov field data: links that
        // were held back here until GATT resolved often dropped first, and the
        // guest never got them). The kernel auto-connect entry, which holds a
        // reference on the link, is kept in the background until bluetoothd's
        // ATT bearer is up (GATT resolved), the link drops, or 10 s pass.
        let up_at = tokio::time::Instant::now();
        info!(%id, after_s = format!("{:.1}", started.elapsed().as_secs_f32()),
              "LE device connected (kernel auto-connect): handing to guest now");
        self.mark_link_up(&id).await;
        self.inner.devices.lock().await.insert(id.clone(), connected.clone());
        let me = self.clone();
        let id2 = id.clone();
        tokio::spawn(async move {
            let mut arm = arm;
            let resolved_by = up_at + SERVICES_RESOLVED_WAIT;
            let mut outcome = "timeout";
            while tokio::time::Instant::now() < resolved_by {
                if connected.is_services_resolved().await.unwrap_or(false) {
                    outcome = "resolved";
                    me.mark_resolved(&id2).await;
                    break;
                }
                if !connected.is_connected().await.unwrap_or(false) {
                    outcome = "dropped";
                    break;
                }
                tokio::time::sleep(Duration::from_millis(100)).await;
            }
            arm.disarm();
            info!(outcome, up_ms = up_at.elapsed().as_millis() as u64,
                  "LE link hold: GATT resolve wait done, auto-connect entry released");
        });
        Ok((id, 23u32))
    }

    async fn connected_device(&self, adapter: &Adapter, want: Address) -> Option<Device> {
        let exists = adapter
            .device_addresses()
            .await
            .map(|v| v.contains(&want))
            .unwrap_or(false);
        if !exists {
            return None;
        }
        let d = adapter.device(want).ok()?;
        if d.is_connected().await.unwrap_or(false) {
            Some(d)
        } else {
            None
        }
    }

    /// Real BlueZ presence of `want`: `adapter.device()` alone always succeeds
    /// (it only builds a D-Bus path), so check the object list and RSSI.
    async fn presence(&self, adapter: &Adapter, want: Address) -> PeerPresence {
        let exists = adapter
            .device_addresses()
            .await
            .map(|v| v.contains(&want))
            .unwrap_or(false);
        let rssi = if exists {
            match adapter.device(want) {
                Ok(d) => d.rssi().await.ok().flatten(),
                Err(_) => None,
            }
        } else {
            None
        };
        peer_presence(exists, rssi)
    }

    /// Make sure BlueZ has a Device object for `address` that is currently
    /// advertising. Fast path: already seen (RSSI) → return at once. Otherwise
    /// join/start discovery (shared, ref-counted bluer session, so the guest
    /// pair scan is not disturbed) until the peer shows up with RSSI or the
    /// budget runs out. Discovery is released when the stream drops.
    async fn ensure_device_known(&self, address: &str, budget: Duration) -> Result<()> {
        let want: Address = address
            .parse()
            .map_err(|e| anyhow!("invalid address {address}: {e}"))?;
        let adapter = self.adapter().await?;
        let initial = self.presence(&adapter, want).await;
        if initial == PeerPresence::Seen {
            debug!(%address, "connect_le: device recently seen, no scan");
            return Ok(());
        }
        let started = tokio::time::Instant::now();
        let transport_name = connect_scan_transport();
        info!(
            %address,
            state = ?initial,
            budget_s = budget.as_secs_f32(),
            transport = transport_name.as_bluez_str(),
            "connect_le: device not seen, scanning"
        );
        let filter = bluer::DiscoveryFilter {
            transport: bluer_transport(transport_name),
            ..Default::default()
        };
        // Fails with DiscoveryActive while a guest scan runs; we then simply
        // join that session (same transport).
        let _ = adapter.set_discovery_filter(filter).await;
        // Owned (boxed) so the explicit drop below releases our discovery ref.
        let mut stream = Box::pin(
            adapter
                .discover_devices_with_changes()
                .await
                .context("discover_devices for connect")?,
        );
        let deadline = started + budget;
        loop {
            let now = tokio::time::Instant::now();
            if now >= deadline {
                break;
            }
            let left = deadline - now;
            let check =
                match tokio::time::timeout(left.min(Duration::from_millis(250)), stream.next())
                    .await
                {
                    Ok(Some(AdapterEvent::DeviceAdded(addr))) => addr == want,
                    Ok(Some(_)) => false,
                    Ok(None) => {
                        debug!(%address, "connect_le: discovery stream ended");
                        break;
                    }
                    Err(_) => true, // tick
                };
            if check && self.presence(&adapter, want).await == PeerPresence::Seen {
                info!(
                    %address,
                    after_s = format!("{:.1}", started.elapsed().as_secs_f32()),
                    "connect_le: found after scan"
                );
                info!(%address, "device seen in discovery");
                return Ok(());
            }
        }
        drop(stream);
        let waited = format!("{:.1}", started.elapsed().as_secs_f32());
        match self.presence(&adapter, want).await {
            PeerPresence::Seen => Ok(()),
            PeerPresence::Stale => {
                // Object exists (e.g. bonded) but no advert heard: let BlueZ try
                // anyway, as before (kernel LE connect waits for an advert).
                info!(%address, after_s = %waited, "connect_le: not heard in scan, trying known device object");
                Ok(())
            }
            PeerPresence::Missing => {
                info!(%address, after_s = %waited, "connect_le: device not found in scan");
                Err(anyhow!("device not found after {waited}s scan"))
            }
        }
    }

    /// Resolve when the LE link to `device_id` is gone: Device1.Connected
    /// flips to false, the object disappears, or it is already down.
    pub async fn wait_link_lost(&self, device_id: &str) -> Result<()> {
        let device = self.device_for_address(device_id).await?;
        let mut events = device.events().await.context("device events")?;
        if !device.is_connected().await.unwrap_or(false) {
            return Ok(());
        }
        while let Some(ev) = events.next().await {
            if let bluer::DeviceEvent::PropertyChanged(bluer::DeviceProperty::Connected(false)) = ev {
                return Ok(());
            }
        }
        Ok(())
    }

    pub async fn disconnect(&self, device_id: &str) -> Result<()> {
        let key = device_id.to_uppercase();
        let device = {
            let map = self.inner.devices.lock().await;
            map.get(&key).cloned()
        };
        if let Some(device) = device {
            device.disconnect().await.context("disconnect")?;
        } else if let Ok(device) = self.device_for_address(device_id).await {
            let _ = device.disconnect().await;
        }
        self.inner.devices.lock().await.remove(&key);
        info!(%device_id, "device disconnected");
        Ok(())
    }

    pub async fn gatt_discover(&self, device_id: &str) -> Result<Vec<GattService>> {
        let device = self.get_connected_device(device_id).await?;
        let mut out = Vec::new();
        let services = device.services().await.context("list services")?;
        for service in services {
            out.push(map_service(&service).await?);
        }
        Ok(out)
    }

    pub async fn gatt_read(
        &self,
        device_id: &str,
        service_uuid: Option<&str>,
        char_uuid: &str,
    ) -> Result<Vec<u8>> {
        let ch = self
            .find_characteristic(device_id, service_uuid, char_uuid)
            .await?;
        let value = ch.read().await.context("gatt read")?;
        Ok(value)
    }

    pub async fn gatt_write(
        &self,
        device_id: &str,
        service_uuid: Option<&str>,
        char_uuid: &str,
        value: &[u8],
        _without_response: bool,
    ) -> Result<()> {
        let ch = self
            .find_characteristic(device_id, service_uuid, char_uuid)
            .await?;
        let mtu = ch.mtu().await.unwrap_or(0);
        if mtu != 0 && value.len() + 3 > mtu as usize {
            debug!(%device_id, %char_uuid, len = value.len(), mtu, "write exceeds ATT MTU — BlueZ uses long (prepared) write");
        }
        ch.write(value).await.context("gatt write")?;
        debug!(%device_id, %char_uuid, mtu, "gatt write done");
        Ok(())
    }

    pub async fn gatt_notify_stream(
        &self,
        device_id: &str,
        service_uuid: Option<&str>,
        char_uuid: &str,
    ) -> Result<impl futures::Stream<Item = Vec<u8>>> {
        let ch = self
            .find_characteristic(device_id, service_uuid, char_uuid)
            .await?;
        let mtu = ch.mtu().await.unwrap_or(0);
        info!(%device_id, %char_uuid, att_mtu = mtu, "enabling notify/indicate");
        let stream = ch.notify().await.context("enable notify")?;
        Ok(stream)
    }

    pub async fn create_bond(&self, address: &str) -> Result<BondState> {
        let _bond = self.inner.bond_lock.lock().await;
        // Device object must exist in BlueZ (scan/discover first).
        self.ensure_device_known(address, Duration::from_secs(15))
            .await
            .context("device not known for bonding")?;
        let device = self.device_for_address(address).await?;
        let adapter = self.adapter().await?;
        info!(%address, "CreateBond: opening pairing window, connecting then pair()");
        // Temporary, non-default agent owned by this process: BlueZ uses the
        // agent of the D-Bus client that calls Pair(), so the guest's bond is
        // Just-Works while every other pairing request still goes to the
        // desktop's default agent. Unregistered when the handle drops.
        let agent: AgentHandle = self
            .inner
            .session
            .register_agent(Agent {
                request_default: false,
                ..Default::default()
            })
            .await
            .context("register temporary pairing agent")?;
        // The kernel only sets SMP's bonding flag (stores keys) when the
        // adapter is bondable, so open it for this pair() only.
        let was_pairable = adapter.is_pairable().await.unwrap_or(false);
        if !was_pairable {
            set_pairable_logged(&adapter, true, "guest bond").await;
        }
        // Best-effort connect before pair (some LE devices require it).
        let _ = tokio::time::timeout(Duration::from_secs(20), device.connect()).await;
        let result = tokio::time::timeout(Duration::from_secs(45), device.pair()).await;
        // Close the pairing window whatever the outcome.
        drop(agent);
        if self.inner.idle_pairable_off || !was_pairable {
            set_pairable_logged(&adapter, false, "bond finished").await;
        }
        result
            .map_err(|_| anyhow!("pair timeout"))?
            .context("pair device")?;
        let paired = device.is_paired().await.unwrap_or(false);
        info!(%address, paired, "CreateBond finished");
        Ok(if paired {
            BondState::Bonded
        } else {
            BondState::Bonding
        })
    }

    pub async fn remove_bond(&self, address: &str) -> Result<()> {
        let adapter = self.adapter().await?;
        let addr: Address = address
            .parse()
            .map_err(|e| anyhow!("invalid address: {e}"))?;
        if let Ok(device) = adapter.device(addr) {
            let _ = device.disconnect().await;
        }
        adapter
            .remove_device(addr)
            .await
            .context("remove_device")?;
        Ok(())
    }

    pub async fn list_bonds(&self) -> Result<Vec<BondedDevice>> {
        let adapter = self.adapter().await?;
        let addrs = adapter.device_addresses().await.context("device_addresses")?;
        let mut out = Vec::new();
        for addr in addrs {
            let device = match adapter.device(addr) {
                Ok(d) => d,
                Err(_) => continue,
            };
            if !device.is_paired().await.unwrap_or(false) {
                continue;
            }
            let name = device.name().await.ok().flatten().unwrap_or_default();
            let addr_type = match device.address_type().await.unwrap_or(AddressType::LePublic) {
                AddressType::LePublic | AddressType::BrEdr => ProtoAddressType::Public,
                AddressType::LeRandom => ProtoAddressType::Random,
            };
            out.push(BondedDevice {
                address: Some(BtAddress {
                    address: addr.to_string(),
                    address_type: addr_type as i32,
                }),
                name,
                state: BondState::Bonded as i32,
            });
        }
        Ok(out)
    }

    pub async fn read_device_adv(&self, address: Address) -> Result<AdvSnapshot> {
        let adapter = self.adapter().await?;
        let device = adapter.device(address).context("device")?;
        let rssi = device.rssi().await.ok().flatten().unwrap_or(0) as i32;
        let name = device
            .alias()
            .await
            .unwrap_or_else(|_| {
                // fallback empty; name() is async so use block-less default
                String::new()
            });
        let name = if name.is_empty() {
            device.name().await.ok().flatten().unwrap_or_default()
        } else {
            name
        };
        let addr_type = match device.address_type().await.unwrap_or(AddressType::LePublic) {
            AddressType::LePublic | AddressType::BrEdr => ProtoAddressType::Public,
            AddressType::LeRandom => ProtoAddressType::Random,
        };
        let uuids = device
            .uuids()
            .await
            .ok()
            .flatten()
            .map(|s| s.into_iter().map(|u| u.to_string()).collect())
            .unwrap_or_default();
        let service_data = device
            .service_data()
            .await
            .ok()
            .flatten()
            .unwrap_or_default()
            .into_iter()
            .map(|(u, d)| (u.to_string(), d))
            .collect();
        let mfg = device
            .manufacturer_data()
            .await
            .ok()
            .flatten()
            .map(|m| {
                let mut out = Vec::new();
                for (id, data) in m {
                    out.extend_from_slice(&id.to_le_bytes());
                    out.extend_from_slice(&data);
                }
                out
            })
            .unwrap_or_default();

        Ok(AdvSnapshot {
            address: address.to_string(),
            address_type: addr_type,
            rssi,
            name,
            connectable: true,
            manufacturer_data: mfg,
            service_data,
            service_uuids: uuids,
        })
    }

    async fn get_connected_device(&self, device_id: &str) -> Result<Device> {
        let key = device_id.to_uppercase();
        if let Some(d) = self.inner.devices.lock().await.get(&key).cloned() {
            return Ok(d);
        }
        let device = self.device_for_address(device_id).await?;
        if !device.is_connected().await.unwrap_or(false) {
            return Err(anyhow!("device not connected: {device_id}"));
        }
        self.inner
            .devices
            .lock()
            .await
            .insert(key, device.clone());
        Ok(device)
    }

    async fn find_characteristic(
        &self,
        device_id: &str,
        service_uuid: Option<&str>,
        char_uuid: &str,
    ) -> Result<Characteristic> {
        let device = self.get_connected_device(device_id).await?;
        let services = device.services().await.context("services")?;
        for service in services {
            if let Some(su) = service_uuid {
                if su.is_empty() {
                    // treat empty as unconstrained
                } else {
                    let uuid = service.uuid().await.context("service uuid")?;
                    if !uuid.to_string().eq_ignore_ascii_case(su) {
                        continue;
                    }
                }
            }
            let chars = service.characteristics().await.context("characteristics")?;
            for ch in chars {
                let uuid = ch.uuid().await.context("char uuid")?;
                if uuid.to_string().eq_ignore_ascii_case(char_uuid) {
                    return Ok(ch);
                }
            }
        }
        Err(anyhow!(
            "characteristic not found: {char_uuid} (service={service_uuid:?})"
        ))
    }
}

#[derive(Clone)]
pub struct AdvSnapshot {
    pub address: String,
    pub address_type: ProtoAddressType,
    pub rssi: i32,
    pub name: String,
    pub connectable: bool,
    pub manufacturer_data: Vec<u8>,
    pub service_data: HashMap<String, Vec<u8>>,
    pub service_uuids: Vec<String>,
}

async fn map_service(service: &Service) -> Result<GattService> {
    let uuid = service.uuid().await?.to_string();
    let primary = service.primary().await.unwrap_or(true);
    let mut characteristics = Vec::new();
    for ch in service.characteristics().await? {
        characteristics.push(map_characteristic(&ch).await?);
    }
    Ok(GattService {
        uuid,
        handle: 0,
        primary,
        characteristics,
    })
}

async fn map_characteristic(ch: &Characteristic) -> Result<GattCharacteristic> {
    let uuid = ch.uuid().await?.to_string();
    let flags = ch.flags().await.unwrap_or_default();
    let mut properties: u32 = 0;
    if flags.read {
        properties |= 0x02;
    }
    if flags.write {
        properties |= 0x08;
    }
    if flags.write_without_response {
        properties |= 0x04;
    }
    if flags.notify {
        properties |= 0x10;
    }
    if flags.indicate {
        properties |= 0x20;
    }

    let mut descriptors = Vec::new();
    if let Ok(descs) = ch.descriptors().await {
        for d in descs {
            let duuid = d.uuid().await?.to_string();
            descriptors.push(GattDescriptor {
                uuid: duuid,
                handle: 0,
            });
        }
    }

    Ok(GattCharacteristic {
        uuid,
        handle: 0,
        properties,
        descriptors,
    })
}

/// Emit an adv snapshot to every matching scan session.
async fn emit_adv_to_sessions(
    bluez: &BlueZ,
    addr: Address,
    tx: &tokio::sync::mpsc::Sender<(u32, AdvSnapshot)>,
    scan_policy: &ScanPolicy,
) -> bool {
    match bluez.read_device_adv(addr).await {
        Ok(snap) => {
            let sessions = scan_policy.matching_sessions(&snap.address, &snap.service_uuids);
            for sid in sessions {
                if tx.send((sid, snap.clone())).await.is_err() {
                    return false;
                }
            }
            true
        }
        Err(e) => {
            debug!(error = %e, "read adv snapshot failed");
            true
        }
    }
}

/// Run discovery while scan sessions exist; emit filtered advertisements.
pub async fn discovery_loop(
    bluez: BlueZ,
    mut stop: tokio::sync::watch::Receiver<bool>,
    tx: tokio::sync::mpsc::Sender<(u32, AdvSnapshot)>,
    scan_policy: Arc<ScanPolicy>,
) {
    loop {
        if *stop.borrow() {
            break;
        }
        if scan_policy.is_empty() {
            tokio::select! {
                _ = stop.changed() => continue,
                _ = tokio::time::sleep(Duration::from_millis(200)) => continue,
            }
        }

        let stream = match bluez.open_discovery_stream().await {
            Ok(s) => s,
            Err(e) => {
                warn!(error = %e, "failed to start discovery; retrying");
                tokio::time::sleep(Duration::from_secs(2)).await;
                continue;
            }
        };
        pin_mut!(stream);
        let transport_name = guest_pair_discovery_transport();
        info!(
            transport = transport_name.as_bluez_str(),
            "dual discovery started (guest pair scan)"
        );

        // Seed already-known BlueZ devices (no DeviceAdded on re-scan). Critical for
        // peripherals probed via ConnectLe earlier in the same host process lifetime.
        if let Ok(adapter) = bluez.adapter().await {
            if let Ok(addrs) = adapter.device_addresses().await {
                for addr in addrs {
                    if scan_policy.is_empty() || *stop.borrow() {
                        break;
                    }
                    if !emit_adv_to_sessions(&bluez, addr, &tx, &scan_policy).await {
                        return;
                    }
                }
            }
        }

        loop {
            if scan_policy.is_empty() || *stop.borrow() {
                info!("dual discovery stopping (no sessions or stop)");
                break;
            }
            tokio::select! {
                _ = stop.changed() => {
                    if *stop.borrow() {
                        break;
                    }
                }
                ev = stream.next() => {
                    match ev {
                        // DeviceAdded (and re-emits from discover_devices_with_changes on
                        // property updates) — inject LE AdvReports into Soft HCI.
                        Some(AdapterEvent::DeviceAdded(addr)) => {
                            if !emit_adv_to_sessions(&bluez, addr, &tx, &scan_policy).await {
                                return;
                            }
                        }
                        Some(AdapterEvent::DeviceRemoved(_))
                        | Some(AdapterEvent::PropertyChanged(_)) => {}
                        None => {
                            debug!("discovery stream ended");
                            break;
                        }
                    }
                }
            }
        }
        tokio::time::sleep(Duration::from_millis(300)).await;
    }
}
