//! HostSim delta core tests: chunk-diff roundtrips, zigzag-varint, wire-format
//! invariants that the GDScript fallback must reproduce byte-identically.

use dfarmy::{chunk_apply_core, chunk_diff_core, hash_bytes, zigzag_pack_core, zigzag_unpack_core};

#[test]
fn chunk_diff_no_change() {
    let a: Vec<u8> = (0..4096u32).map(|i| (i % 251) as u8).collect();
    let (bm, data, chunks, changed) = chunk_diff_core(&a, &a, 512).unwrap();
    assert_eq!(chunks, 8);
    assert_eq!(changed, 0);
    assert!(data.is_empty());
    assert!(bm.iter().all(|&b| b == 0));
}

#[test]
fn chunk_diff_all_changed_partial_last_chunk() {
    let old: Vec<u8> = vec![0u8; 1000];
    let new: Vec<u8> = (0..1000u32).map(|i| (i * 7 % 255) as u8).collect();
    let chunk = 256; // 1000 = 3*256 + 232: the last chunk is partial
    let (bm, data, chunks, changed) = chunk_diff_core(&old, &new, chunk).unwrap();
    assert_eq!(chunks, 4);
    assert_eq!(changed, 4);
    assert_eq!(data.len(), 1000);
    assert_eq!(bm, vec![0b00001111]);
    // apply: roundtrip
    let back = chunk_apply_core(&old, &bm, &data, chunk, new.len()).unwrap();
    assert_eq!(back, new);
}

#[test]
fn chunk_diff_only_middle_chunk() {
    let mut old: Vec<u8> = vec![1u8; 1024];
    let mut new: Vec<u8> = vec![1u8; 1024];
    for b in &mut new[512..768] {
        *b = 9;
    }
    let (bm, data, chunks, changed) = chunk_diff_core(&old, &new, 256).unwrap();
    assert_eq!(chunks, 4);
    assert_eq!(changed, 1);
    assert_eq!(data.len(), 256);
    assert_eq!(bm, vec![0b00000100]); // chunk #2 set, LSB-first
    let _ = old.len();
    let back = chunk_apply_core(&old, &bm, &data, 256, new.len()).unwrap();
    assert_eq!(back, new);
}

#[test]
fn chunk_diff_size_mismatch_is_none() {
    let a = vec![0u8; 100];
    let b = vec![0u8; 99];
    assert!(chunk_diff_core(&a, &b, 16).is_none());
    assert!(chunk_diff_core(&a, &a, 0).is_none());
    assert!(chunk_apply_core(&a, &[1], &[9; 16], 16, 101).is_none());
}

#[test]
fn chunk_apply_truncated_data_is_none() {
    let old = vec![0u8; 256];
    let bm = [0b00000011u8];
    let short = vec![9u8; 100]; // two chunks worth promised, only half arrived
    assert!(chunk_apply_core(&old, &bm, &short, 256, 256).is_none());
}

#[test]
fn zigzag_roundtrip_small_and_negative() {
    let vals: Vec<i64> = vec![0, 1, -1, 2, -2, 63, -64, 127, -128, 255, -255,
        100000, -100000, i32::MAX as i64, -(i32::MAX as i64) - 1, i64::MAX, i64::MIN];
    let packed = zigzag_pack_core(&vals);
    assert_eq!(zigzag_unpack_core(&packed), vals);
}

#[test]
fn zigzag_small_values_are_compact() {
    assert_eq!(zigzag_pack_core(&[0]).len(), 1);
    assert_eq!(zigzag_pack_core(&[63]).len(), 1);
    assert_eq!(zigzag_pack_core(&[16384]).len(), 3);
    assert_eq!(zigzag_pack_core(&[0; 100]).len(), 100);
}

#[test]
fn zigzag_truncated_tail_does_not_panic() {
    let packed = zigzag_pack_core(&[1, 2, 3, -4]);
    let cut = &packed[..packed.len() - 1];
    let v = zigzag_unpack_core(cut);
    assert!(v.len() >= 3 && v.len() <= 4);
}

#[test]
fn checksum_is_stable_and_length_sensitive() {
    let a = vec![1u8, 2, 3];
    let b = vec![1u8, 2, 3, 4];
    assert_eq!(hash_bytes(&a), hash_bytes(&a));
    assert_ne!(hash_bytes(&a), hash_bytes(&b));
}
