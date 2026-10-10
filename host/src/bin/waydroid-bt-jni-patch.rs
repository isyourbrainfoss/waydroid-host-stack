//! Patch Lineage 20 / TQ3A `libbluetooth_jni.so` so Fluoride's timerfd uses
//! `CLOCK_BOOTTIME` (7) instead of `CLOCK_BOOTTIME_ALARM` (9).
//!
//! Std-only Rust port of `scripts/waydroid-patch-bt-jni-timerfd.py`, so the
//! phone host does not need python3 (image-based hosts such as Nura/Duranium
//! ship without it).
//!
//! Sites: the three known TQ3A offsets if they match; otherwise the patcher
//! resolves `timerfd_create@plt` from .rela.plt/.dynsym and scans .text for
//! `mov w0,#9` right before `bl timerfd_create` (rebuilt images move code).
//!
//! Usage:
//!   waydroid-bt-jni-patch INPUT.so OUTPUT.so
//!   waydroid-bt-jni-patch --check INPUT.so
use std::process::ExitCode;

const MOV_W0_IMM9: u32 = 0x5280_0000 | (9 << 5);
const MOV_W0_IMM7: u32 = 0x5280_0000 | (7 << 5);
/// Virtual addresses of `mov w0, #9` before `bl timerfd_create@plt`
/// (Lineage 20 TQ3A arm64 libbluetooth_jni.so).
const DEFAULT_SITES: [u64; 3] = [0xAAD400, 0xAAF340, 0xB34BC8];

fn rd_u16(d: &[u8], o: usize) -> Result<u16, String> {
    d.get(o..o + 2)
        .map(|b| u16::from_le_bytes([b[0], b[1]]))
        .ok_or_else(|| format!("truncated ELF at {o:#x}"))
}
fn rd_u32(d: &[u8], o: usize) -> Result<u32, String> {
    d.get(o..o + 4)
        .map(|b| u32::from_le_bytes(b.try_into().unwrap()))
        .ok_or_else(|| format!("truncated ELF at {o:#x}"))
}
fn rd_u64(d: &[u8], o: usize) -> Result<u64, String> {
    d.get(o..o + 8)
        .map(|b| u64::from_le_bytes(b.try_into().unwrap()))
        .ok_or_else(|| format!("truncated ELF at {o:#x}"))
}

/// Map a virtual address to a file offset via PT_LOAD program headers.
pub fn va_to_off(d: &[u8], va: u64) -> Result<usize, String> {
    let phoff = rd_u64(d, 32)? as usize;
    let phentsize = rd_u16(d, 54)? as usize;
    let phnum = rd_u16(d, 56)? as usize;
    for i in 0..phnum {
        let off = phoff + i * phentsize;
        if rd_u32(d, off)? != 1 {
            continue;
        }
        let p_offset = rd_u64(d, off + 8)?;
        let p_vaddr = rd_u64(d, off + 16)?;
        let p_filesz = rd_u64(d, off + 32)?;
        let p_memsz = rd_u64(d, off + 40)?;
        if p_vaddr <= va && va < p_vaddr + p_memsz {
            let file_off = p_offset + (va - p_vaddr);
            if file_off + 4 > p_offset + p_filesz {
                return Err(format!("va {va:#x} maps outside file-backed LOAD"));
            }
            return Ok(file_off as usize);
        }
    }
    Err(format!("va {va:#x} not in any PT_LOAD"))
}


struct Section {
    name: String,
    addr: u64,
    offset: u64,
    size: u64,
    link: u32,
}

fn sections(d: &[u8]) -> Result<Vec<Section>, String> {
    let shoff = rd_u64(d, 0x28)? as usize;
    let shentsize = rd_u16(d, 0x3a)? as usize;
    let shnum = rd_u16(d, 0x3c)? as usize;
    let shstrndx = rd_u16(d, 0x3e)? as usize;
    let mut raw = Vec::new();
    for i in 0..shnum {
        let o = shoff + i * shentsize;
        raw.push((
            rd_u32(d, o)?,
            rd_u64(d, o + 0x10)?,
            rd_u64(d, o + 0x18)?,
            rd_u64(d, o + 0x20)?,
            rd_u32(d, o + 0x28)?,
        ));
    }
    let stroff = raw.get(shstrndx).ok_or("bad shstrndx")?.2 as usize;
    Ok(raw
        .into_iter()
        .map(|(n, addr, offset, size, link)| Section {
            name: cstr(d, stroff + n as usize),
            addr,
            offset,
            size,
            link,
        })
        .collect())
}

fn cstr(d: &[u8], o: usize) -> String {
    let end = d[o.min(d.len())..].iter().position(|&b| b == 0).map(|p| o + p).unwrap_or(d.len());
    String::from_utf8_lossy(&d[o.min(d.len())..end]).into_owned()
}

/// Address of the `timerfd_create@plt` stub (AArch64 lazy PLT layout:
/// 32-byte header, then one 16-byte stub per .rela.plt entry, in order).
fn timerfd_plt_addr(d: &[u8]) -> Result<u64, String> {
    let secs = sections(d)?;
    let find = |n: &str| secs.iter().find(|s| s.name == n).ok_or(format!("no {n} section"));
    let rela = find(".rela.plt")?;
    let plt = find(".plt")?;
    let dynsym = secs.get(rela.link as usize).ok_or("bad .rela.plt link")?;
    let dynstr = secs.get(dynsym.link as usize).ok_or("bad .dynsym link")?;
    let n = (rela.size / 24) as usize;
    for i in 0..n {
        let o = rela.offset as usize + i * 24;
        let info = rd_u64(d, o + 8)?;
        let sym = (info >> 32) as usize;
        let name_off = rd_u32(d, dynsym.offset as usize + sym * 24)? as usize;
        if cstr(d, dynstr.offset as usize + name_off) == "timerfd_create" {
            return Ok(plt.addr + 0x20 + 16 * i as u64);
        }
    }
    Err("timerfd_create not imported".into())
}

/// Scan .text for `mov w0,#9|#7` up to 4 insns before `bl timerfd_create@plt`
/// (only `mov w1,wzr` / insns not writing w0 in between). Returns VAs.
pub fn scan_sites(d: &[u8]) -> Result<Vec<u64>, String> {
    let target = timerfd_plt_addr(d)?;
    let secs = sections(d)?;
    let text = secs.iter().find(|s| s.name == ".text").ok_or("no .text")?;
    let mut out = Vec::new();
    let mut i = 0u64;
    while i + 4 <= text.size {
        let insn = rd_u32(d, (text.offset + i) as usize)?;
        if insn & 0xfc00_0000 == 0x9400_0000 {
            let imm = (insn & 0x03ff_ffff) as i64;
            let imm = (imm << 38) >> 36; // sign-extend 26 bits, *4
            let pc = text.addr + i;
            if pc.wrapping_add(imm as u64) == target {
                let mut k = 1u64;
                while k <= 4 && i >= 4 * k {
                    let prev = rd_u32(d, (text.offset + i - 4 * k) as usize)?;
                    if prev == MOV_W0_IMM9 || prev == MOV_W0_IMM7 {
                        out.push(pc - 4 * k);
                        break;
                    }
                    // stop if something else writes w0/x0 (Rd==0, data-processing)
                    if prev & 0x1f == 0 && prev & 0x1c00_0000 != 0x0800_0000 {
                        break;
                    }
                    k += 1;
                }
            }
        }
        i += 4;
    }
    Ok(out)
}

/// Known sites if they match, otherwise scanned sites.
fn resolve_sites(d: &[u8]) -> Result<Vec<u64>, String> {
    let known_ok = DEFAULT_SITES.iter().all(|&va| {
        va_to_off(d, va)
            .and_then(|o| rd_u32(d, o))
            .map(|c| c == MOV_W0_IMM9 || c == MOV_W0_IMM7)
            .unwrap_or(false)
    });
    if known_ok {
        return Ok(DEFAULT_SITES.to_vec());
    }
    let s = scan_sites(d)?;
    if s.is_empty() {
        return Err("no `mov w0,#9; bl timerfd_create` sites found".into());
    }
    Ok(s)
}

/// Returns (patched_now, already_patched). Errors on unexpected instructions.
pub fn patch(d: &mut [u8], dry_run: bool) -> Result<(usize, usize), String> {
    if d.len() < 64 || &d[..4] != b"\x7fELF" {
        return Err("not an ELF file".into());
    }
    if d[4] != 2 || d[5] != 1 {
        return Err("expected ELF64 little-endian".into());
    }
    let sites = if d.len() > 0x40 && rd_u16(d, 0x3c).unwrap_or(0) > 0 {
        resolve_sites(d)?
    } else {
        DEFAULT_SITES.to_vec()
    };
    let mut offs = Vec::new();
    for va in sites {
        let off = va_to_off(d, va)?;
        let cur = rd_u32(d, off)?;
        if cur != MOV_W0_IMM9 && cur != MOV_W0_IMM7 {
            return Err(format!(
                "unexpected insn at va {va:#x} off {off:#x}: {cur:08x} \
                 (want {MOV_W0_IMM9:08x} or already-patched {MOV_W0_IMM7:08x}) \
                 — not a Lineage 20 TQ3A libbluetooth_jni.so?"
            ));
        }
        offs.push((off, cur));
    }
    let (mut n, mut already) = (0, 0);
    for (off, cur) in offs {
        if cur == MOV_W0_IMM7 {
            already += 1;
        } else {
            if !dry_run {
                d[off..off + 4].copy_from_slice(&MOV_W0_IMM7.to_le_bytes());
            }
            n += 1;
        }
    }
    Ok((n, already))
}

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let (check, rest): (bool, Vec<&String>) = {
        let check = args.iter().any(|a| a == "--check");
        (check, args.iter().filter(|a| *a != "--check").collect())
    };
    if rest.is_empty() || rest.iter().any(|a| *a == "-h" || *a == "--help") {
        eprintln!("usage: waydroid-bt-jni-patch INPUT.so OUTPUT.so | --check INPUT.so");
        return ExitCode::from(2);
    }
    let mut data = match std::fs::read(rest[0]) {
        Ok(d) => d,
        Err(e) => {
            eprintln!("read {}: {e}", rest[0]);
            return ExitCode::from(2);
        }
    };
    if check {
        return match patch(&mut data, true) {
            Ok((n, a)) => {
                println!("CHECK_OK sites={} need_patch={n} already={a}", n + a);
                ExitCode::SUCCESS
            }
            Err(e) => {
                eprintln!("CHECK_FAIL {e}");
                ExitCode::from(4)
            }
        };
    }
    let Some(out) = rest.get(1) else {
        eprintln!("output path required unless --check");
        return ExitCode::from(2);
    };
    match patch(&mut data, false) {
        Ok((n, _)) => {
            if let Err(e) = std::fs::write(out, &data) {
                eprintln!("write {out}: {e}");
                return ExitCode::from(2);
            }
            println!("PATCH_OK wrote {out} patched_insns={n}");
            ExitCode::SUCCESS
        }
        Err(e) => {
            eprintln!("PATCH_FAIL {e}");
            ExitCode::from(3)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Minimal ELF64 with one PT_LOAD mapping va 0xA00000.. to file offset 0x1000.
    fn fake_elf(insn: u32) -> Vec<u8> {
        let base_va: u64 = 0xA0_0000;
        let file_base: u64 = 0x1000;
        let size: u64 = 0x20_0000;
        let mut d = vec![0u8; (file_base + size) as usize];
        d[..4].copy_from_slice(b"\x7fELF");
        d[4] = 2;
        d[5] = 1;
        d[32..40].copy_from_slice(&64u64.to_le_bytes());
        d[54..56].copy_from_slice(&56u16.to_le_bytes());
        d[56..58].copy_from_slice(&1u16.to_le_bytes());
        let ph = 64;
        d[ph..ph + 4].copy_from_slice(&1u32.to_le_bytes());
        d[ph + 8..ph + 16].copy_from_slice(&file_base.to_le_bytes());
        d[ph + 16..ph + 24].copy_from_slice(&base_va.to_le_bytes());
        d[ph + 32..ph + 40].copy_from_slice(&size.to_le_bytes());
        d[ph + 40..ph + 48].copy_from_slice(&size.to_le_bytes());
        for va in DEFAULT_SITES {
            let off = (file_base + va - base_va) as usize;
            d[off..off + 4].copy_from_slice(&insn.to_le_bytes());
        }
        d
    }

    #[test]
    fn patches_and_is_idempotent() {
        let mut d = fake_elf(MOV_W0_IMM9);
        assert_eq!(patch(&mut d, false).unwrap(), (3, 0));
        assert_eq!(patch(&mut d, false).unwrap(), (0, 3));
    }

    #[test]
    fn dry_run_does_not_modify() {
        let mut d = fake_elf(MOV_W0_IMM9);
        let before = d.clone();
        assert_eq!(patch(&mut d, true).unwrap(), (3, 0));
        assert_eq!(d, before);
    }

    #[test]
    fn rejects_unknown_build() {
        let mut d = fake_elf(0xd503_201f); // nop
        assert!(patch(&mut d, false).is_err());
    }

    #[test]
    fn rejects_non_elf() {
        let mut d = vec![0u8; 128];
        assert!(patch(&mut d, true).is_err());
    }
}
