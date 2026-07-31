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

#[cfg(test)]
mod tests {
    use super::*;

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
