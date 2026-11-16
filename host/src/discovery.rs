//! Pure helpers for host discovery transport selection.
//!
//! Guest Settings "Pair new device" issues classic HCI Inquiry as well as LE
//! scan. Host BlueZ must therefore use dual (auto) transport — not LE-only —
//! so BR/EDR devices (Xbox controllers, classic headsets, etc.) can appear.

/// BlueZ `org.bluez.Adapter1.SetDiscoveryFilter` Transport values we support.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DiscoveryTransportName {
    /// LE advertisements only (historical default — insufficient for Xbox-class).
    #[allow(dead_code)]
    Le,
    /// BR/EDR inquiry only.
    #[allow(dead_code)]
    BrEdr,
    /// Interleaved dual discovery (BlueZ "auto"). Preferred for guest pair UI.
    Auto,
}

impl DiscoveryTransportName {
    /// Wire string for BlueZ / bluer `DiscoveryTransport`.
    pub fn as_bluez_str(self) -> &'static str {
        match self {
            Self::Le => "le",
            Self::BrEdr => "bredr",
            Self::Auto => "auto",
        }
    }

    /// True when classic BR/EDR inquiry may run (not LE-only).
    pub fn includes_classic(self) -> bool {
        matches!(self, Self::Auto | Self::BrEdr)
    }

    /// True when LE advertisements may be collected.
    pub fn includes_le(self) -> bool {
        matches!(self, Self::Auto | Self::Le)
    }
}

/// Transport used when the guest starts discovery (StartLeScan / Inquiry bridge).
///
/// Always dual so Soft HCI Inquiry+EIR and LE Adv reports both get RF traffic.
pub fn guest_pair_discovery_transport() -> DiscoveryTransportName {
    DiscoveryTransportName::Auto
}

/// Parse a transport name (for tests and config). Accepts "dual" as alias of "auto".
#[cfg_attr(not(test), allow(dead_code))]
pub fn parse_discovery_transport(s: &str) -> Option<DiscoveryTransportName> {
    match s.trim().to_ascii_lowercase().as_str() {
        "le" => Some(DiscoveryTransportName::Le),
        "bredr" | "br/edr" | "classic" => Some(DiscoveryTransportName::BrEdr),
        "auto" | "dual" => Some(DiscoveryTransportName::Auto),
        _ => None,
    }
}

/// Default cap on the pre-connect scan in `connect_le` (seconds).
pub const DEFAULT_CONNECT_SCAN_SECS: u64 = 12;
/// Env override for the pre-connect scan cap (`WAYDROID_BT_CONNECT_SCAN_SECS`).
pub const CONNECT_SCAN_SECS_ENV: &str = "WAYDROID_BT_CONNECT_SCAN_SECS";

/// Pre-connect scan budget: the env cap (default 12 s, clamped 1..=60 s),
/// never longer than the guest's own connect timeout.
pub fn connect_scan_budget_from(
    timeout: std::time::Duration,
    env_secs: Option<&str>,
) -> std::time::Duration {
    let cap = env_secs
        .and_then(|v| v.trim().parse::<u64>().ok())
        .unwrap_or(DEFAULT_CONNECT_SCAN_SECS)
        .clamp(1, 60);
    timeout.min(std::time::Duration::from_secs(cap))
}

/// How present a peer is in BlueZ right now.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PeerPresence {
    /// No org.bluez Device1 object (temporary device expired / never seen).
    Missing,
    /// Device object exists but has no RSSI: not seen in the current discovery.
    Stale,
    /// Device object with RSSI: advertising right now, connect directly.
    Seen,
}

pub fn peer_presence(object_exists: bool, rssi: Option<i16>) -> PeerPresence {
    match (object_exists, rssi) {
        (false, _) => PeerPresence::Missing,
        (true, None) => PeerPresence::Stale,
        (true, Some(_)) => PeerPresence::Seen,
    }
}

/// BlueZ Connect errors worth one rescan + retry (transient LE link setup
/// aborts, or the object vanished between scan and Connect).
pub fn is_retryable_connect_error(msg: &str) -> bool {
    let m = msg.to_ascii_lowercase();
    [
        "le-connection-abort",
        "connection-abort",
        "software caused connection abort",
        "does not exist",
        "unknownobject",
        "unknown object",
        "page-timeout",
    ]
    .iter()
    .any(|k| m.contains(k))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn connect_scan_budget_default_env_and_cap() {
        use std::time::Duration;
        let t30 = Duration::from_secs(30);
        assert_eq!(connect_scan_budget_from(t30, None), Duration::from_secs(12));
        assert_eq!(
            connect_scan_budget_from(t30, Some("15")),
            Duration::from_secs(15)
        );
        assert_eq!(
            connect_scan_budget_from(t30, Some("junk")),
            Duration::from_secs(12)
        );
        assert_eq!(
            connect_scan_budget_from(t30, Some("0")),
            Duration::from_secs(1)
        );
        assert_eq!(connect_scan_budget_from(t30, Some("999")), t30);
        assert_eq!(
            connect_scan_budget_from(Duration::from_secs(5), None),
            Duration::from_secs(5),
            "never longer than the guest timeout"
        );
    }

    #[test]
    fn presence_classification() {
        assert_eq!(peer_presence(false, None), PeerPresence::Missing);
        assert_eq!(peer_presence(false, Some(-60)), PeerPresence::Missing);
        assert_eq!(peer_presence(true, None), PeerPresence::Stale);
        assert_eq!(peer_presence(true, Some(-70)), PeerPresence::Seen);
    }

    #[test]
    fn retryable_connect_errors() {
        assert!(is_retryable_connect_error(
            "org.bluez.Error.Failed: le-connection-abort-by-local"
        ));
        assert!(is_retryable_connect_error(
            "Software caused connection abort"
        ));
        assert!(is_retryable_connect_error(
            "org.bluez.Error.DoesNotExist: Does Not Exist"
        ));
        assert!(is_retryable_connect_error(
            "org.freedesktop.DBus.Error.UnknownObject: Method Connect doesn't exist"
        ));
        assert!(!is_retryable_connect_error("org.bluez.Error.NotAuthorized"));
        assert!(!is_retryable_connect_error("connect timeout"));
    }

    #[test]
    fn guest_pair_uses_dual_not_le_only() {
        let t = guest_pair_discovery_transport();
        assert_eq!(t, DiscoveryTransportName::Auto);
        assert_eq!(t.as_bluez_str(), "auto");
        assert!(t.includes_classic(), "classic path must not be LE-only");
        assert!(t.includes_le(), "LE path must still work");
    }

    #[test]
    fn parse_aliases_and_reject_unknown() {
        assert_eq!(
            parse_discovery_transport("DUAL"),
            Some(DiscoveryTransportName::Auto)
        );
        assert_eq!(
            parse_discovery_transport("le"),
            Some(DiscoveryTransportName::Le)
        );
        assert_eq!(
            parse_discovery_transport("bredr"),
            Some(DiscoveryTransportName::BrEdr)
        );
        assert!(parse_discovery_transport("wifi").is_none());
    }

    #[test]
    fn le_only_excludes_classic() {
        let t = DiscoveryTransportName::Le;
        assert!(!t.includes_classic());
        assert!(t.includes_le());
    }
}
