//! Structural + functional tests for the shipped timerfd patch helper.
//!
//! Drives `scripts/waydroid-patch-bt-jni-timerfd.py` as the real entry point
//! (not a reimplementation). Uses a minimal AArch64 ELF fixture embedding the
//! three known `mov w0, #9` sites at the same virtual addresses as production
//! libbluetooth_jni.so so the VA→offset mapper and patch path are exercised.

use std::path::PathBuf;
use std::process::Command;

fn repo_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("host crate parent")
        .to_path_buf()
}

fn patch_script() -> PathBuf {
    repo_root().join("scripts/waydroid-patch-bt-jni-timerfd.py")
}

/// Build a tiny ET_DYN AArch64 ELF with PT_LOAD covering 0..size and place
/// `mov w0,#9` (or #7) at the three production VAs.
fn make_fixture(already_patched: bool) -> Vec<u8> {
    // Minimal ELF64: e_ident + header + one PT_LOAD mapping file offset = vaddr.
    // Sites are high (~0xbxxxxx); fixture size must cover max VA + 4.
    const SIZE: usize = 0xB34C00;
    let mut data = vec![0u8; SIZE];

    // ELF identification
    data[0..4].copy_from_slice(b"\x7fELF");
    data[4] = 2; // ELFCLASS64
    data[5] = 1; // ELFDATA2LSB
    data[6] = 1; // EV_CURRENT

    // e_type = ET_DYN (3), e_machine = EM_AARCH64 (183)
    data[16] = 3;
    data[17] = 0;
    data[18] = 183;
    data[19] = 0;
    // e_version
    data[20] = 1;

    // e_phoff = 64
    data[32] = 64;
    // e_ehsize = 64
    data[52] = 64;
    // e_phentsize = 56
    data[54] = 56;
    // e_phnum = 1
    data[56] = 1;

    // Program header at 64: PT_LOAD
    let ph = 64usize;
    // p_type = PT_LOAD (1)
    data[ph] = 1;
    // p_flags = PF_R|PF_X (5)
    data[ph + 4] = 5;
    // p_offset = 0, p_vaddr = 0, p_paddr = 0
    // p_filesz = SIZE, p_memsz = SIZE
    let size_u64 = SIZE as u64;
    data[ph + 32..ph + 40].copy_from_slice(&size_u64.to_le_bytes());
    data[ph + 40..ph + 48].copy_from_slice(&size_u64.to_le_bytes());

    // mov w0, #9  => 0x52800120 ; mov w0, #7 => 0x528000e0
    let insn: u32 = if already_patched {
        0x5280_00e0
    } else {
        0x5280_0120
    };
    let bytes = insn.to_le_bytes();
    for va in [0x00AAD400usize, 0x00AAF340, 0x00B34BC8] {
        data[va..va + 4].copy_from_slice(&bytes);
    }
    data
}

#[test]
fn patch_script_exists() {
    assert!(
        patch_script().is_file(),
        "missing shipped patch script at {:?}",
        patch_script()
    );
}

#[test]
fn patch_rewrites_boottime_alarm_sites() {
    let script = patch_script();
    let dir = tempfile::tempdir().expect("tempdir");
    let input = dir.path().join("libbluetooth_jni.so");
    let output = dir.path().join("libbluetooth_jni.patched.so");
    std::fs::write(&input, make_fixture(false)).unwrap();

    let out = Command::new("python3")
        .arg(&script)
        .arg(&input)
        .arg(&output)
        .output()
        .expect("run patch script");
    assert!(
        out.status.success(),
        "patch failed: stdout={} stderr={}",
        String::from_utf8_lossy(&out.stdout),
        String::from_utf8_lossy(&out.stderr)
    );
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(
        stdout.contains("PATCH_OK") && stdout.contains("patched_insns=3"),
        "unexpected stdout: {stdout}"
    );

    let patched = std::fs::read(&output).unwrap();
    let want = 0x5280_00e0u32.to_le_bytes();
    for va in [0x00AAD400usize, 0x00AAF340, 0x00B34BC8] {
        assert_eq!(
            &patched[va..va + 4],
            &want,
            "site {va:#x} not patched to CLOCK_BOOTTIME"
        );
    }

    // --check on patched file succeeds with need_patch=0
    let chk = Command::new("python3")
        .arg(&script)
        .arg("--check")
        .arg(&output)
        .output()
        .unwrap();
    assert!(chk.status.success());
    let s = String::from_utf8_lossy(&chk.stdout);
    assert!(s.contains("CHECK_OK") && s.contains("need_patch=0"), "{s}");
}

#[test]
fn check_accepts_unpatched_fixture() {
    let script = patch_script();
    let dir = tempfile::tempdir().unwrap();
    let input = dir.path().join("lib.so");
    std::fs::write(&input, make_fixture(false)).unwrap();
    let chk = Command::new("python3")
        .arg(&script)
        .arg("--check")
        .arg(&input)
        .output()
        .unwrap();
    assert!(chk.status.success());
    let s = String::from_utf8_lossy(&chk.stdout);
    assert!(s.contains("need_patch=3"), "{s}");
}
