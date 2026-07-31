//! Host-side policy for shared BlueZ use.
//!
//! - Adapter power: BlueZ is source of truth. Guest "power off" is soft-disable
//!   by default so host Phosh/bluetui keep the radio.
//! - LE scan sessions are refcounted; BlueZ discovery stops only when last session ends.

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};

use tracing::{debug, info};

/// Guest-visible soft-disable without touching BlueZ power.
#[derive(Debug, Default)]
pub struct PowerPolicy {
    guest_soft_disabled: AtomicBool,
}

impl PowerPolicy {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn guest_soft_disabled(&self) -> bool {
        self.guest_soft_disabled.load(Ordering::SeqCst)
    }

    /// Apply guest power request.
    /// Returns whether BlueZ power should be changed (`Some(desired)`).
    pub fn set_guest_powered(&self, powered: bool, force_host: bool) -> Option<bool> {
        if force_host {
            self.guest_soft_disabled.store(!powered, Ordering::SeqCst);
            info!(powered, "guest requested force_host power change");
            return Some(powered);
        }
        // Soft-disable: Android thinks BT is off; host radio stays as-is.
        self.guest_soft_disabled.store(!powered, Ordering::SeqCst);
        info!(
            powered,
            soft_disabled = !powered,
            "guest soft power change (BlueZ untouched)"
        );
        None
    }

    #[allow(dead_code)]
    pub fn clear_soft_disable(&self) {
        self.guest_soft_disabled.store(false, Ordering::SeqCst);
    }
}

/// Refcounted LE scan sessions.
#[derive(Debug, Default)]
pub struct ScanPolicy {
    next_id: AtomicU32,
    /// session_id -> active
    sessions: std::sync::Mutex<HashMap<u32, ScanSession>>,
}

#[derive(Debug, Clone)]
pub struct ScanSession {
    pub service_uuids: Vec<String>,
    pub addresses: Vec<String>,
    #[allow(dead_code)]
    pub active: bool,
}

impl ScanPolicy {
    pub fn new() -> Self {
        Self {
            next_id: AtomicU32::new(1),
            sessions: std::sync::Mutex::new(HashMap::new()),
        }
    }

    pub fn start(&self, session: ScanSession) -> u32 {
        let id = self.next_id.fetch_add(1, Ordering::SeqCst);
        let mut map = self.sessions.lock().expect("scan lock");
        map.insert(id, session);
        debug!(session_id = id, count = map.len(), "scan session started");
        id
    }

    pub fn stop(&self, session_id: u32) -> bool {
        let mut map = self.sessions.lock().expect("scan lock");
        let removed = map.remove(&session_id).is_some();
        debug!(
            session_id,
            removed,
            count = map.len(),
            "scan session stop"
        );
        removed
    }

    pub fn is_empty(&self) -> bool {
        self.sessions.lock().expect("scan lock").is_empty()
    }

    #[allow(dead_code)]
    pub fn session_count(&self) -> usize {
        self.sessions.lock().expect("scan lock").len()
    }

    #[allow(dead_code)]
    pub fn get(&self, session_id: u32) -> Option<ScanSession> {
        self.sessions
            .lock()
            .expect("scan lock")
            .get(&session_id)
            .cloned()
    }

    #[allow(dead_code)]
    pub fn all_sessions(&self) -> Vec<(u32, ScanSession)> {
        self.sessions
            .lock()
            .expect("scan lock")
            .iter()
            .map(|(k, v)| (*k, v.clone()))
            .collect()
    }

    /// Whether an advertisement matches any active session filters.
    /// Returns list of matching session ids.
    pub fn matching_sessions(
        &self,
        address: &str,
        service_uuids: &[String],
    ) -> Vec<u32> {
        let map = self.sessions.lock().expect("scan lock");
        let addr_norm = address.to_uppercase();
        map.iter()
            .filter_map(|(id, s)| {
                if !s.addresses.is_empty() {
                    let ok = s
                        .addresses
                        .iter()
                        .any(|a| a.to_uppercase() == addr_norm);
                    if !ok {
                        return None;
                    }
                }
                if !s.service_uuids.is_empty() {
                    let ok = s.service_uuids.iter().any(|need| {
                        service_uuids.iter().any(|have| {
                            have.eq_ignore_ascii_case(need)
                        })
                    });
                    if !ok {
                        return None;
                    }
                }
                Some(*id)
            })
            .collect()
    }

    pub fn clear(&self) {
        self.sessions.lock().expect("scan lock").clear();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn soft_disable_does_not_touch_host() {
        let p = PowerPolicy::new();
        assert!(!p.guest_soft_disabled());
        assert!(p.set_guest_powered(false, false).is_none());
        assert!(p.guest_soft_disabled());
        assert!(p.set_guest_powered(true, false).is_none());
        assert!(!p.guest_soft_disabled());
    }

    #[test]
    fn force_host_returns_power() {
        let p = PowerPolicy::new();
        assert_eq!(p.set_guest_powered(false, true), Some(false));
        assert!(p.guest_soft_disabled());
        assert_eq!(p.set_guest_powered(true, true), Some(true));
    }

    #[test]
    fn scan_refcount() {
        let s = ScanPolicy::new();
        let id1 = s.start(ScanSession {
            service_uuids: vec![],
            addresses: vec![],
            active: true,
        });
        let id2 = s.start(ScanSession {
            service_uuids: vec!["180d".into()],
            addresses: vec![],
            active: false,
        });
        assert_eq!(s.session_count(), 2);
        assert!(s.stop(id1));
        assert_eq!(s.session_count(), 1);
        assert!(!s.is_empty());
        assert!(s.stop(id2));
        assert!(s.is_empty());
    }

    #[test]
    fn scan_filters() {
        let s = ScanPolicy::new();
        let id = s.start(ScanSession {
            service_uuids: vec!["0000180d-0000-1000-8000-00805f9b34fb".into()],
            addresses: vec!["AA:BB:CC:DD:EE:FF".into()],
            active: true,
        });
        let m = s.matching_sessions(
            "aa:bb:cc:dd:ee:ff",
            &["0000180d-0000-1000-8000-00805f9b34fb".into()],
        );
        assert_eq!(m, vec![id]);
        assert!(s
            .matching_sessions("11:22:33:44:55:66", &["0000180d-0000-1000-8000-00805f9b34fb".into()])
            .is_empty());
    }
}
