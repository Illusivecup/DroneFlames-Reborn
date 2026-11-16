//! Determinism tests: the same seed / the same input = the same output, always.

use dfarmy::{hash_bytes, hash_floats, Xo256};

#[test]
fn rng_stream_is_seed_deterministic() {
    let mut a = Xo256::new(12345);
    let mut b = Xo256::new(12345);
    for _ in 0..1000 {
        assert_eq!(a.next_u64(), b.next_u64());
    }
    let mut c = Xo256::new(12346);
    let mut d = Xo256::new(12345);
    assert_ne!(c.next_u64(), d.next_u64());
}

#[test]
fn rng_seed_zero_is_not_dead() {
    let mut a = Xo256::new(0);
    let mut b = Xo256::new(0);
    for _ in 0..100 {
        let x = a.next_u64();
        assert_eq!(x, b.next_u64());
        assert_ne!(x, 0);
    }
}

#[test]
fn rng_below_is_in_range_and_uniform_enough() {
    let mut a = Xo256::new(777);
    let mut hits = [0u32; 10];
    for _ in 0..10_000 {
        let v = a.below(10) as usize;
        hits[v] += 1;
    }
    for h in hits {
        assert!(h > 700 && h < 1300, "uniformity broken: {:?}", hits);
    }
}

#[test]
fn hash_canonicalizes_floats() {
    assert_eq!(hash_floats(&[0.0]), hash_floats(&[-0.0]));
    assert_eq!(hash_floats(&[f64::NAN]), hash_floats(&[-f64::NAN]));
    assert_ne!(hash_floats(&[1.0]), hash_floats(&[1.0, 1.0]));
    assert_ne!(hash_floats(&[1.0, 2.0]), hash_floats(&[2.0, 1.0]));
    let v = [1.5, -2.25, 3.14159265358979, 0.1];
    assert_eq!(hash_floats(&v), hash_floats(&v));
}

#[test]
fn hash_bytes_stability() {
    let v: Vec<u8> = (0..1000u16).map(|i| (i % 251) as u8).collect();
    assert_eq!(hash_bytes(&v), hash_bytes(&v));
    let mut w = v.clone();
    w[500] ^= 1;
    assert_ne!(hash_bytes(&v), hash_bytes(&w));
    let mut t = v.clone();
    t.push(9);
    assert_ne!(hash_bytes(&v), hash_bytes(&t));
}

#[test]
fn f64_stays_in_range() {
    let mut a = Xo256::new(9);
    for _ in 0..100 {
        let f = a.next_f64();
        assert!((0.0..1.0).contains(&f));
    }
}
