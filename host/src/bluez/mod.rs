//! BlueZ access via bluer (official Rust bindings).

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

use crate::discovery::{guest_pair_discovery_transport, DiscoveryTransportName};
use crate::policy::{PowerPolicy, ScanPolicy};

#[derive(Clone)]
pub struct BlueZ {
    inner: Arc<BlueZInner>,
}

struct BlueZInner {
    _session: Session,
    /// Keep pairing agent registered for Just-Works / auto-confirm bonds.
    _agent: AgentHandle,
    adapter: RwLock<Option<Adapter>>,
    power: PowerPolicy,
    /// device_id (address string) -> open device handle
    devices: Mutex<HashMap<String, Device>>,
    #[allow(dead_code)]
    adapter_events: broadcast::Sender<AdapterInfo>,
}

fn bluer_transport(name: DiscoveryTransportName) -> DiscoveryTransport {
    match name {
        DiscoveryTransportName::Le => DiscoveryTransport::Le,
        DiscoveryTransportName::BrEdr => DiscoveryTransport::BrEdr,
        DiscoveryTransportName::Auto => DiscoveryTransport::Auto,
    }
}

impl BlueZ {
    pub async fn connect(power: PowerPolicy) -> Result<Self> {
        let session = Session::new()
            .await
            .context("connect to BlueZ session (is bluetoothd running?)")?;
        // NoInputNoOutput default agent accepts Just-Works; request_default so
        // CreateBond does not hang waiting for an interactive host agent.
        let agent = Agent {
            request_default: true,
            ..Default::default()
        };
        let agent_handle = session
            .register_agent(agent)
            .await
            .context("register BlueZ pairing agent")?;
        info!("BlueZ pairing agent registered (default, Just-Works capable)");

        let adapter = session
            .default_adapter()
            .await
            .context("no default Bluetooth adapter")?;
        let adapter_name = adapter.name().to_string();
        info!(adapter = %adapter_name, "BlueZ adapter opened");

        let (tx, _) = broadcast::channel(64);
        Ok(Self {
            inner: Arc::new(BlueZInner {
                _session: session,
                _agent: agent_handle,
                adapter: RwLock::new(Some(adapter)),
                power,
                devices: Mutex::new(HashMap::new()),
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

    pub async fn connect_le(&self, address: &str, timeout_ms: u32) -> Result<(String, u32)> {
        let timeout = if timeout_ms == 0 {
            Duration::from_secs(30)
        } else {
            Duration::from_millis(timeout_ms as u64)
        };

        // Ensure the device object exists (discovery may be required).
        self.ensure_device_known(address, timeout.min(Duration::from_secs(12)))
            .await?;

        let device = self.device_for_address(address).await?;
        // Already connected (guest reconnect / race after Soft HCI teardown): reuse.
        if device.is_connected().await.unwrap_or(false) {
            let id = address.to_uppercase();
            self.inner
                .devices
                .lock()
                .await
                .insert(id.clone(), device);
            info!(%id, "LE device already connected — reuse");
            return Ok((id, 23u32));
        }
        debug!(%address, "connecting LE device");
        tokio::time::timeout(timeout, device.connect())
            .await
            .map_err(|_| anyhow!("connect timeout"))?
            .context("device.connect")?;

        let id = address.to_uppercase();
        self.inner
            .devices
            .lock()
            .await
            .insert(id.clone(), device);
        // MTU not always exposed via D-Bus; common LE default.
        let mtu = 23u32;
        info!(%id, mtu, "LE device connected");
        Ok((id, mtu))
    }

    /// Start a short dual discovery so BlueZ creates the Device object for `address`.
    async fn ensure_device_known(&self, address: &str, budget: Duration) -> Result<()> {
        if self.device_for_address(address).await.is_ok() {
            // Even if the object exists, it may be stale; still try a brief scan.
        }
        let want: Address = address
            .parse()
            .map_err(|e| anyhow!("invalid address {address}: {e}"))?;
        let adapter = self.adapter().await?;
        let transport_name = guest_pair_discovery_transport();
        let filter = bluer::DiscoveryFilter {
            transport: bluer_transport(transport_name),
            ..Default::default()
        };
        let _ = adapter.set_discovery_filter(filter).await;
        let stream = adapter
            .discover_devices()
            .await
            .context("discover_devices for connect")?;
        pin_mut!(stream);
        let deadline = tokio::time::Instant::now() + budget;
        while tokio::time::Instant::now() < deadline {
            let left = deadline.saturating_duration_since(tokio::time::Instant::now());
            match tokio::time::timeout(left.min(Duration::from_millis(500)), stream.next()).await {
                Ok(Some(AdapterEvent::DeviceAdded(addr))) if addr == want => {
                    info!(%address, "device seen in discovery");
                    break;
                }
                Ok(Some(_)) => continue,
                Ok(None) => break,
                Err(_) => {
                    // timeout tick — check if device object exists now
                    if self.device_for_address(address).await.is_ok() {
                        break;
                    }
                }
            }
        }
        // Final existence check
        self.device_for_address(address)
            .await
            .map(|_| ())
            .context("device not found after discovery")
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
        // Device object must exist in BlueZ (scan/discover first).
        self.ensure_device_known(address, Duration::from_secs(15))
            .await
            .context("device not known for bonding")?;
        let device = self.device_for_address(address).await?;
        info!(%address, "CreateBond: connecting then pair()");
        // Best-effort connect before pair (some LE devices require it).
        let _ = tokio::time::timeout(Duration::from_secs(20), device.connect()).await;
        tokio::time::timeout(Duration::from_secs(45), device.pair())
            .await
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
