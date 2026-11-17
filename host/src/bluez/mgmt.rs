//! Minimal BlueZ kernel management (mgmt) client for LE auto-connect.
//!
//! Used for "car absent" background connects (Tesla phone key, FP5 B55
//! follow-up): instead of polling with active scans, the bridge asks the
//! kernel to keep the peer on its LE auto-connect list (MGMT Add Device,
//! action 0x02). The kernel then runs a low-duty passive scan with the
//! controller's Filter Accept List and connects as soon as the peer
//! advertises, exactly what an Android controller does for an
//! `autoConnect` GATT client. bluetoothd sees an ordinary incoming LE
//! connection and resolves GATT; the bridge picks the link up from D-Bus.
//!
//! Scan duty comes from bluetoothd's `[LE] ScanIntervalAutoConnect` /
//! `ScanWindowAutoConnect` (main.conf, read at bluetoothd start).
//!
//! Needs CAP_NET_ADMIN and AF_BLUETOOTH (see the unit drop-in
//! `70-passive-autoconnect.conf`). Without them arming fails with
//! `Unsupported` and the guest HAL falls back to active retries.

use std::io;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
use std::time::{Duration, Instant};

pub const MGMT_OP_ADD_DEVICE: u16 = 0x0033;
pub const MGMT_OP_REMOVE_DEVICE: u16 = 0x0034;
pub const MGMT_EV_CMD_COMPLETE: u16 = 0x0001;
pub const MGMT_EV_CMD_STATUS: u16 = 0x0002;

/// mgmt address types.
pub const MGMT_ADDR_LE_PUBLIC: u8 = 0x01;
pub const MGMT_ADDR_LE_RANDOM: u8 = 0x02;

/// Add Device action: auto-connect remote device.
pub const MGMT_ACTION_AUTO_CONNECT: u8 = 0x02;

const AF_BLUETOOTH: libc::c_int = 31;
const BTPROTO_HCI: libc::c_int = 1;
const HCI_DEV_NONE: u16 = 0xffff;
const HCI_CHANNEL_CONTROL: u16 = 3;

#[repr(C)]
struct SockaddrHci {
    hci_family: libc::sa_family_t,
    hci_dev: u16,
    hci_channel: u16,
}

#[derive(Debug, thiserror::Error)]
pub enum MgmtError {
    /// No mgmt access (sandbox, missing CAP_NET_ADMIN, old kernel).
    #[error("mgmt unavailable: {0}")]
    Unavailable(String),
    /// Kernel answered with a non-zero mgmt status.
    #[error("mgmt status 0x{0:02x}")]
    Status(u8),
    #[error("mgmt i/o: {0}")]
    Io(String),
}

/// "AA:BB:CC:DD:EE:FF" -> little-endian bdaddr bytes (pure).
pub fn parse_bdaddr_le(s: &str) -> Option<[u8; 6]> {
    let parts: Vec<&str> = s.split(':').collect();
    if parts.len() != 6 {
        return None;
    }
    let mut out = [0u8; 6];
    for (i, p) in parts.iter().enumerate() {
        if p.len() != 2 {
            return None;
        }
        out[5 - i] = u8::from_str_radix(p, 16).ok()?;
    }
    Some(out)
}

/// Adapter name "hci0" -> controller index 0 (pure).
pub fn hci_index_from_name(name: &str) -> Option<u16> {
    name.strip_prefix("hci")?.parse().ok()
}

/// Protocol AddressType (1=PUBLIC, 2=RANDOM, 0=unspecified) -> mgmt LE type.
pub fn mgmt_le_addr_type(proto_address_type: i32) -> u8 {
    if proto_address_type == 2 {
        MGMT_ADDR_LE_RANDOM
    } else {
        MGMT_ADDR_LE_PUBLIC
    }
}

fn header(opcode: u16, index: u16, plen: u16) -> Vec<u8> {
    let mut v = Vec::with_capacity(6 + plen as usize);
    v.extend_from_slice(&opcode.to_le_bytes());
    v.extend_from_slice(&index.to_le_bytes());
    v.extend_from_slice(&plen.to_le_bytes());
    v
}

/// MGMT_OP_ADD_DEVICE packet (pure).
pub fn encode_add_device(index: u16, addr: [u8; 6], addr_type: u8, action: u8) -> Vec<u8> {
    let mut v = header(MGMT_OP_ADD_DEVICE, index, 8);
    v.extend_from_slice(&addr);
    v.push(addr_type);
    v.push(action);
    v
}

/// MGMT_OP_REMOVE_DEVICE packet (pure).
pub fn encode_remove_device(index: u16, addr: [u8; 6], addr_type: u8) -> Vec<u8> {
    let mut v = header(MGMT_OP_REMOVE_DEVICE, index, 7);
    v.extend_from_slice(&addr);
    v.push(addr_type);
    v
}

/// If `buf` is the Command Complete / Command Status for `opcode` on
/// `index`, return its status byte (pure). Other mgmt events -> None.
pub fn parse_cmd_result(buf: &[u8], opcode: u16, index: u16) -> Option<u8> {
    if buf.len() < 6 + 3 {
        return None;
    }
    let ev = u16::from_le_bytes([buf[0], buf[1]]);
    let idx = u16::from_le_bytes([buf[2], buf[3]]);
    if idx != index || (ev != MGMT_EV_CMD_COMPLETE && ev != MGMT_EV_CMD_STATUS) {
        return None;
    }
    let op = u16::from_le_bytes([buf[6], buf[7]]);
    if op != opcode {
        return None;
    }
    Some(buf[8])
}

fn open_control() -> Result<OwnedFd, MgmtError> {
    // SAFETY: plain socket(2)/bind(2) calls; fd ownership moves into OwnedFd.
    unsafe {
        let fd = libc::socket(
            AF_BLUETOOTH,
            libc::SOCK_RAW | libc::SOCK_CLOEXEC | libc::SOCK_NONBLOCK,
            BTPROTO_HCI,
        );
        if fd < 0 {
            return Err(MgmtError::Unavailable(
                io::Error::last_os_error().to_string(),
            ));
        }
        let fd = OwnedFd::from_raw_fd(fd);
        let sa = SockaddrHci {
            hci_family: AF_BLUETOOTH as libc::sa_family_t,
            hci_dev: HCI_DEV_NONE,
            hci_channel: HCI_CHANNEL_CONTROL,
        };
        let r = libc::bind(
            fd.as_raw_fd(),
            &sa as *const SockaddrHci as *const libc::sockaddr,
            std::mem::size_of::<SockaddrHci>() as libc::socklen_t,
        );
        if r < 0 {
            return Err(MgmtError::Unavailable(
                io::Error::last_os_error().to_string(),
            ));
        }
        Ok(fd)
    }
}

/// Send one mgmt command and wait (blocking, <= `timeout`) for its result.
fn command(pkt: &[u8], opcode: u16, index: u16, timeout: Duration) -> Result<(), MgmtError> {
    let fd = open_control()?;
    // SAFETY: valid fd and buffer.
    let n = unsafe { libc::send(fd.as_raw_fd(), pkt.as_ptr().cast(), pkt.len(), 0) };
    if n < 0 {
        let e = io::Error::last_os_error();
        // EPERM/EACCES: no CAP_NET_ADMIN -> treat as unavailable.
        return Err(match e.raw_os_error() {
            Some(libc::EPERM) | Some(libc::EACCES) => MgmtError::Unavailable(e.to_string()),
            _ => MgmtError::Io(e.to_string()),
        });
    }
    let start = Instant::now();
    let mut buf = [0u8; 1024];
    loop {
        let left = timeout.saturating_sub(start.elapsed());
        if left.is_zero() {
            return Err(MgmtError::Io("timeout waiting for mgmt reply".into()));
        }
        let mut pfd = libc::pollfd {
            fd: fd.as_raw_fd(),
            events: libc::POLLIN,
            revents: 0,
        };
        // SAFETY: one valid pollfd.
        let pr = unsafe { libc::poll(&mut pfd, 1, left.as_millis().min(i32::MAX as u128) as i32) };
        if pr < 0 {
            let e = io::Error::last_os_error();
            if e.kind() == io::ErrorKind::Interrupted {
                continue;
            }
            return Err(MgmtError::Io(e.to_string()));
        }
        if pr == 0 {
            continue;
        }
        // SAFETY: valid fd and buffer.
        let n = unsafe { libc::recv(fd.as_raw_fd(), buf.as_mut_ptr().cast(), buf.len(), 0) };
        if n < 0 {
            let e = io::Error::last_os_error();
            if e.kind() == io::ErrorKind::WouldBlock || e.kind() == io::ErrorKind::Interrupted {
                continue;
            }
            return Err(MgmtError::Io(e.to_string()));
        }
        // 0x14 = MGMT_STATUS_PERMISSION_DENIED (socket without CAP_NET_ADMIN).
        match parse_cmd_result(&buf[..n as usize], opcode, index) {
            Some(0) => return Ok(()),
            Some(0x14) => return Err(MgmtError::Unavailable("mgmt permission denied".into())),
            Some(s) => return Err(MgmtError::Status(s)),
            None => continue, // unrelated broadcast mgmt event
        }
    }
}

const MGMT_TIMEOUT: Duration = Duration::from_secs(3);

/// Put `addr` on the kernel LE auto-connect list.
pub fn add_auto_connect(index: u16, addr: [u8; 6], addr_type: u8) -> Result<(), MgmtError> {
    command(
        &encode_add_device(index, addr, addr_type, MGMT_ACTION_AUTO_CONNECT),
        MGMT_OP_ADD_DEVICE,
        index,
        MGMT_TIMEOUT,
    )
}

/// Take `addr` off the kernel auto-connect list (an existing link stays up).
pub fn remove_device(index: u16, addr: [u8; 6], addr_type: u8) -> Result<(), MgmtError> {
    command(
        &encode_remove_device(index, addr, addr_type),
        MGMT_OP_REMOVE_DEVICE,
        index,
        MGMT_TIMEOUT,
    )
}

/// RAII arm: on drop the peer is removed from the auto-connect list again,
/// also when the waiting request is cancelled (guest socket closed).
pub struct AutoConnectArm {
    index: u16,
    addr: [u8; 6],
    addr_type: u8,
    armed: bool,
}

impl AutoConnectArm {
    pub fn arm(index: u16, addr: [u8; 6], addr_type: u8) -> Result<Self, MgmtError> {
        add_auto_connect(index, addr, addr_type)?;
        Ok(Self {
            index,
            addr,
            addr_type,
            armed: true,
        })
    }

    /// Disarm now (idempotent).
    pub fn disarm(&mut self) {
        if self.armed {
            self.armed = false;
            if let Err(e) = remove_device(self.index, self.addr, self.addr_type) {
                tracing::warn!(error = %e, "passive auto-connect: disarm failed");
            }
        }
    }
}

impl Drop for AutoConnectArm {
    fn drop(&mut self) {
        self.disarm();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bdaddr_is_little_endian() {
        assert_eq!(
            parse_bdaddr_le("AA:BB:CC:DD:EE:01"),
            Some([0x01, 0xEE, 0xDD, 0xCC, 0xBB, 0xAA])
        );
        assert_eq!(parse_bdaddr_le("AA:BB:CC:DD:EE"), None);
        assert_eq!(parse_bdaddr_le("AA:BB:CC:DD:EE:GG"), None);
        assert_eq!(parse_bdaddr_le("AAB:B:CC:DD:EE:01"), None);
    }

    #[test]
    fn hci_index() {
        assert_eq!(hci_index_from_name("hci0"), Some(0));
        assert_eq!(hci_index_from_name("hci12"), Some(12));
        assert_eq!(hci_index_from_name("wlan0"), None);
    }

    #[test]
    fn addr_type_mapping() {
        assert_eq!(mgmt_le_addr_type(0), MGMT_ADDR_LE_PUBLIC);
        assert_eq!(mgmt_le_addr_type(1), MGMT_ADDR_LE_PUBLIC);
        assert_eq!(mgmt_le_addr_type(2), MGMT_ADDR_LE_RANDOM);
    }

    #[test]
    fn add_device_packet_layout() {
        let a = [1, 2, 3, 4, 5, 6];
        let p = encode_add_device(0, a, MGMT_ADDR_LE_PUBLIC, MGMT_ACTION_AUTO_CONNECT);
        assert_eq!(
            p,
            vec![0x33, 0x00, 0x00, 0x00, 0x08, 0x00, 1, 2, 3, 4, 5, 6, 0x01, 0x02]
        );
        let r = encode_remove_device(1, a, MGMT_ADDR_LE_RANDOM);
        assert_eq!(
            r,
            vec![0x34, 0x00, 0x01, 0x00, 0x07, 0x00, 1, 2, 3, 4, 5, 6, 0x02]
        );
    }

    #[test]
    fn cmd_result_matches_only_own_reply() {
        // Command Complete, index 0, len 10, opcode 0x0033, status 0, addr+type
        let ok = [
            0x01, 0x00, 0x00, 0x00, 0x0a, 0x00, 0x33, 0x00, 0x00, 1, 2, 3, 4, 5, 6, 1,
        ];
        assert_eq!(parse_cmd_result(&ok, MGMT_OP_ADD_DEVICE, 0), Some(0));
        assert_eq!(parse_cmd_result(&ok, MGMT_OP_REMOVE_DEVICE, 0), None);
        assert_eq!(parse_cmd_result(&ok, MGMT_OP_ADD_DEVICE, 1), None);
        // Command Status with Permission Denied (0x14)
        let st = [0x02, 0x00, 0x00, 0x00, 0x03, 0x00, 0x34, 0x00, 0x14];
        assert_eq!(parse_cmd_result(&st, MGMT_OP_REMOVE_DEVICE, 0), Some(0x14));
        // Device Found (0x0012) is ignored
        let other = [0x12, 0x00, 0x00, 0x00, 0x03, 0x00, 0x33, 0x00, 0x00];
        assert_eq!(parse_cmd_result(&other, MGMT_OP_ADD_DEVICE, 0), None);
        assert_eq!(parse_cmd_result(&[0x01, 0x00], MGMT_OP_ADD_DEVICE, 0), None);
    }
}
