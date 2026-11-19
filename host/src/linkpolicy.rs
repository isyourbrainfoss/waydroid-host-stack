//! LE link hand-over / early-drop policy (FP5 Tesla phone key, 2026-11-19).
//!
//! Field data (19 Nov): the car's kernel auto-connects often dropped within
//! milliseconds, before GATT resolved; the bridge only noticed after the drop
//! and ended the guest's request ("LE link lost"), so the phone key never got
//! a usable link. Policy (pure, unit tested):
//!  * hand a kernel auto-connect to the guest at once (no blocking wait for
//!    ServicesResolved; the auto-connect reference is held in the background
//!    until GATT is up),
//!  * a link that drops "early" (within the threshold, or before GATT ever
//!    resolved) and that the guest has not started using (no notify streams)
//!    gets ONE active reconnect instead of a link-lost event to the guest.

use std::time::Duration;

/// Env override for the early-drop threshold (milliseconds).
pub const EARLY_DROP_ENV: &str = "WHS_EARLY_DROP_MS";
pub const EARLY_DROP_DEFAULT_MS: u64 = 1000;
/// A link that never resolved GATT within this window also counts as early.
pub const UNRESOLVED_WINDOW: Duration = Duration::from_secs(10);
/// Active reconnect budget after an early drop (scan + connect).
pub const EARLY_RECONNECT_TIMEOUT_MS: u32 = 8000;

pub fn early_drop_threshold(env: Option<&str>) -> Duration {
    let ms = env
        .and_then(|s| s.trim().parse::<u64>().ok())
        .unwrap_or(EARLY_DROP_DEFAULT_MS)
        .clamp(100, 10_000);
    Duration::from_millis(ms)
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DropAction {
    /// One active reconnect; the guest is not told (it never used the link).
    Reconnect,
    /// Tell the guest the link is lost (old behaviour).
    TellGuest,
}

impl DropAction {
    pub fn as_str(self) -> &'static str {
        match self {
            DropAction::Reconnect => "early-reconnect",
            DropAction::TellGuest => "tell-guest",
        }
    }
}

/// Decide what to do when BlueZ reports Connected=false.
/// `up`: how long the link had been up (None = unknown).
pub fn drop_action(
    up: Option<Duration>,
    services_resolved: bool,
    notify_streams: usize,
    already_retried: bool,
    threshold: Duration,
) -> DropAction {
    if already_retried || notify_streams > 0 {
        return DropAction::TellGuest;
    }
    match up {
        Some(d) if d <= threshold => DropAction::Reconnect,
        Some(d) if !services_resolved && d <= UNRESOLVED_WINDOW => DropAction::Reconnect,
        _ => DropAction::TellGuest,
    }
}

/// Content of /run/waydroid-bt/features (lets tesla-frunk-root.sh check that
/// the running bridge handles SIGUSR1 before sending it).
pub fn features_line(pid: u32) -> String {
    format!("kick-usr1 early-drop-reconnect pid={pid}\n")
}

#[cfg(test)]
mod tests {
    use super::*;

    const T: Duration = Duration::from_millis(1000);

    #[test]
    fn threshold_default_and_clamp() {
        assert_eq!(early_drop_threshold(None), Duration::from_millis(1000));
        assert_eq!(early_drop_threshold(Some("1500")), Duration::from_millis(1500));
        assert_eq!(early_drop_threshold(Some("5")), Duration::from_millis(100));
        assert_eq!(early_drop_threshold(Some("999999")), Duration::from_millis(10_000));
        assert_eq!(early_drop_threshold(Some("junk")), Duration::from_millis(1000));
    }

    #[test]
    fn early_drop_reconnects_once() {
        let a = drop_action(Some(Duration::from_millis(300)), false, 0, false, T);
        assert_eq!(a, DropAction::Reconnect);
        // second drop after the retry: guest is told
        let b = drop_action(Some(Duration::from_millis(300)), false, 0, true, T);
        assert_eq!(b, DropAction::TellGuest);
    }

    #[test]
    fn unresolved_link_counts_as_early_within_window() {
        assert_eq!(drop_action(Some(Duration::from_secs(4)), false, 0, false, T), DropAction::Reconnect);
        assert_eq!(drop_action(Some(Duration::from_secs(4)), true, 0, false, T), DropAction::TellGuest);
        assert_eq!(drop_action(Some(Duration::from_secs(30)), false, 0, false, T), DropAction::TellGuest);
    }

    #[test]
    fn link_in_use_is_never_hidden() {
        assert_eq!(drop_action(Some(Duration::from_millis(200)), false, 1, false, T), DropAction::TellGuest);
    }

    #[test]
    fn unknown_age_tells_guest() {
        assert_eq!(drop_action(None, false, 0, false, T), DropAction::TellGuest);
    }

    #[test]
    fn features_line_has_marker_and_pid() {
        assert_eq!(features_line(42), "kick-usr1 early-drop-reconnect pid=42\n");
    }
}
