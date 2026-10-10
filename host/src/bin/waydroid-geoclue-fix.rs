//! Keep a GeoClue2 client alive on the system bus and mirror every location
//! update into a small state file for the root Waydroid GPS injector.
//!
//! Replaces the python3+dbus reader in waydroid-gps-forward.sh (image-based
//! hosts have no python3). Runs as root from waydroid-geoclue-fix.service; the
//! DesktopId must be allowed in geoclue's config
//! (/etc/geoclue/conf.d/90-waydroid-host-stack.conf, system=true).
//!
//! Output (atomic rename), one line:
//!   lat|lon|accuracy_m|altitude_m|speed_mps|heading_deg|unix_ts|description
//!
//! Usage: waydroid-geoclue-fix [--out PATH] [--desktop-id ID] [--accuracy-level N] [--once]
use dbus::blocking::stdintf::org_freedesktop_dbus::Properties;
use dbus::blocking::Connection;
use dbus::message::MatchRule;
use dbus::Path;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

const GC: &str = "org.freedesktop.GeoClue2";
const CLIENT: &str = "org.freedesktop.GeoClue2.Client";
const LOC: &str = "org.freedesktop.GeoClue2.Location";
const T: Duration = Duration::from_secs(10);

struct Args {
    out: String,
    desktop_id: String,
    level: u32,
    once: bool,
}

fn parse_args() -> Args {
    let mut a = Args {
        out: "/run/waydroid-host-stack/gps-fix".into(),
        desktop_id: "waydroid-gps-forward".into(),
        level: 8,
        once: false,
    };
    let mut it = std::env::args().skip(1);
    while let Some(x) = it.next() {
        match x.as_str() {
            "--out" => a.out = it.next().unwrap_or(a.out),
            "--desktop-id" => a.desktop_id = it.next().unwrap_or(a.desktop_id),
            "--accuracy-level" => a.level = it.next().and_then(|v| v.parse().ok()).unwrap_or(8),
            "--once" => a.once = true,
            _ => {
                eprintln!("usage: waydroid-geoclue-fix [--out PATH] [--desktop-id ID] [--accuracy-level N] [--once]");
                std::process::exit(2);
            }
        }
    }
    a
}

/// Format a finite number; GeoClue uses -DBL_MAX for "unknown".
fn num(v: Option<f64>) -> String {
    match v {
        Some(x) if x.is_finite() && x.abs() < 1e100 => {
            let s = format!("{x:.7}");
            s.trim_end_matches('0').trim_end_matches('.').to_string()
        }
        _ => String::new(),
    }
}

pub fn format_fix(lat: f64, lon: f64, acc: Option<f64>, alt: Option<f64>, speed: Option<f64>,
                  heading: Option<f64>, ts: u64, desc: &str) -> Option<String> {
    if !lat.is_finite() || !lon.is_finite() || lat.abs() > 90.0 || lon.abs() > 180.0 {
        return None;
    }
    let speed = speed.filter(|s| *s >= 0.0);
    let heading = heading.filter(|h| *h >= 0.0);
    let desc: String = desc.chars().filter(|c| *c != '|' && *c != '\n').collect();
    Some(format!(
        "{}|{}|{}|{}|{}|{}|{}|{}",
        num(Some(lat)), num(Some(lon)), num(acc.or(Some(50.0))), num(alt), num(speed), num(heading), ts, desc
    ))
}

fn write_atomic(path: &str, line: &str) -> std::io::Result<()> {
    if let Some(dir) = std::path::Path::new(path).parent() {
        std::fs::create_dir_all(dir)?;
    }
    let tmp = format!("{path}.tmp");
    std::fs::write(&tmp, format!("{line}\n"))?;
    std::fs::rename(tmp, path)
}

fn read_location(conn: &Connection, loc: &Path<'static>) -> Result<Option<String>, dbus::Error> {
    let p = conn.with_proxy(GC, loc.clone(), T);
    let f = |name: &str| -> Option<f64> { p.get::<f64>(LOC, name).ok() };
    let lat: f64 = p.get(LOC, "Latitude")?;
    let lon: f64 = p.get(LOC, "Longitude")?;
    let desc: String = p.get(LOC, "Description").unwrap_or_default();
    let ts = SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0);
    Ok(format_fix(lat, lon, f("Accuracy"), f("Altitude"), f("Speed"), f("Heading"), ts, &desc))
}

fn run(a: &Args) -> Result<(), Box<dyn std::error::Error>> {
    let conn = Connection::new_system()?;
    let mgr = conn.with_proxy(GC, "/org/freedesktop/GeoClue2/Manager", T);
    let (client_path,): (Path<'static>,) = mgr.method_call("org.freedesktop.GeoClue2.Manager", "GetClient", ())?;
    let client = conn.with_proxy(GC, client_path.clone(), T);
    client.set(CLIENT, "DesktopId", a.desktop_id.clone())?;
    client.set(CLIENT, "RequestedAccuracyLevel", a.level)?;
    client.set(CLIENT, "DistanceThreshold", 0u32)?;
    client.set(CLIENT, "TimeThreshold", 0u32)?;

    let out = a.out.clone();
    let once = a.once;
    let rule = MatchRule::new_signal(CLIENT, "LocationUpdated").with_path(client_path.clone());
    conn.add_match(rule, move |(_old, new): (Path<'static>, Path<'static>), c: &Connection, _m| {
        match read_location(c, &new) {
            Ok(Some(line)) => {
                if let Err(e) = write_atomic(&out, &line) {
                    eprintln!("write {out}: {e}");
                } else {
                    println!("FIX {line}");
                    if once {
                        std::process::exit(0);
                    }
                }
            }
            Ok(None) => eprintln!("ignoring invalid location"),
            Err(e) => eprintln!("read location: {e}"),
        }
        true
    })?;
    let _: () = client.method_call(CLIENT, "Start", ())?;
    eprintln!("GEOCLUE_CLIENT_STARTED path={client_path} desktop_id={}", a.desktop_id);
    // Keep the client alive; GeoClue drops it when this connection closes.
    let mut idle = 0u32;
    loop {
        if conn.process(Duration::from_secs(5))? {
            idle = 0;
        } else {
            idle += 1;
            // Liveness: GeoClue may stop signalling while stationary; refresh
            // the timestamp from the current Location every ~60 s.
            if idle % 12 == 0 {
                if let Ok(loc) = client.get::<Path<'static>>(CLIENT, "Location") {
                    if &*loc != "/" {
                        if let Ok(Some(line)) = read_location(&conn, &loc) {
                            let _ = write_atomic(&a.out, &line);
                        }
                    }
                }
            }
        }
    }
}

fn main() {
    let a = parse_args();
    if let Err(e) = run(&a) {
        eprintln!("GEOCLUE_FIX_ERROR {e}");
        std::process::exit(1);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn formats_and_filters_unknowns() {
        let l = format_fix(59.93516, 10.946037, Some(1.0), Some(176.8), Some(-1.0), Some(-1.0), 100, "GPS GGA+RMC").unwrap();
        assert_eq!(l, "59.93516|10.946037|1|176.8|||100|GPS GGA+RMC");
        let l = format_fix(1.0, 2.0, None, Some(-1.7976931348623157e308), None, None, 5, "a|b").unwrap();
        assert_eq!(l, "1|2|50||||5|ab");
        assert!(format_fix(f64::NAN, 1.0, None, None, None, None, 0, "").is_none());
        assert!(format_fix(91.0, 1.0, None, None, None, None, 0, "").is_none());
    }
}
