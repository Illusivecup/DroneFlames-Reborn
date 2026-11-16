//! dfnet — deterministic primitives for the lockstep multiplayer.
//!
//! - [`DfRng`]: xoshiro256++ seeded by splitmix64. Every device draws the same
//!   sequence from the same seed; the state serializes into four words, so a
//!   snapshot carries it losslessly.
//! - [`DfHash`]: FxHash-based state hashing: canonical float bits (±0.0 unified,
//!   NaN payloads unified), 64-bit digest, hex string. A device-independent
//!   replacement for the MD5 pipeline in `net/net_hash.gd` (the GDScript side
//!   keeps its MD5 fallback while the extension ships).
//! - [`DfDelta`]: HostSim v1.2 — chunk-diff of the big world arrays (owners /
//!   obj_state) and zigzag-varint packing of id/mask streams. The GDScript side
//!   (`net/hs_codec.gd`) has a byte-identical fallback when the extension is
//!   absent, so the wire format is the same with and without Rust.

use godot::prelude::*;

// ------------------------------------------------------------------ hashing

/// FxHash (rustc-hash) mix round, 64-bit — a fast, stable, dependency-free mixer.
#[inline(always)]
const fn fx_round(hash: u64, v: u64) -> u64 {
    (hash.rotate_left(5) ^ v).wrapping_mul(0x51_7C_C1_B7_27_22_0A_4D)
}

/// The canonical bits of an f64: +0.0 / -0.0 unify to +0.0, every NaN payload
/// unifies to the quiet NaN 0x7ff8000000000000. Everything else is exact.
#[inline(always)]
fn canonical_bits(x: f64) -> u64 {
    if x.is_nan() {
        return 0x7ff8_0000_0000_0000;
    }
    if x == 0.0 {
        return 0u64; // +0.0 and -0.0 compare equal: hash equal
    }
    x.to_bits()
}

/// A 64-bit state digest of a float stream: canonical bits fed through the Fx mix.
pub fn hash_floats(nums: &[f64]) -> u64 {
    let mut h: u64 = 0;
    for &x in nums {
        h = fx_round(h, canonical_bits(x));
    }
    fx_round(h, nums.len() as u64) // length in: ["a"] != [] != ["a","a"]
}

/// A 64-bit digest of raw bytes (the object-state / owners arrays).
pub fn hash_bytes(data: &[u8]) -> u64 {
    let mut h: u64 = 0;
    let mut chunks = data.chunks_exact(8);
    for c in &mut chunks {
        let mut w: u64 = 0;
        for (i, &b) in c.iter().enumerate() {
            w |= (b as u64) << (8 * i);
        }
        h = fx_round(h, w);
    }
    let tail = chunks.remainder();
    if !tail.is_empty() {
        let mut w: u64 = 0;
        for (i, &b) in tail.iter().enumerate() {
            w |= (b as u64) << (8 * i);
        }
        h = fx_round(h, w);
    }
    fx_round(h, data.len() as u64)
}

fn hex64(v: u64) -> GString {
    let s: String = format!("{v:016x}");
    GString::from(s.as_str())
}

// ------------------------------------------------------------------ the class

#[derive(GodotClass)]
#[class(base=RefCounted, init)]
pub struct DfHash {
    base: Base<RefCounted>,
}

#[godot_api]
impl DfHash {
    /// Hex digest of a float stream (the NetHash pipeline's numbers).
    #[func]
    fn floats(&self, nums: PackedFloat64Array) -> GString {
        hex64(hash_floats(nums.as_slice()))
    }

    /// Hex digest of raw bytes.
    #[func]
    fn bytes(&self, data: PackedByteArray) -> GString {
        hex64(hash_bytes(data.as_slice()))
    }

    /// The 64-bit digest as a (stable, JSON-safe) decimal string — for logs.
    #[func]
    fn floats_u64(&self, nums: PackedFloat64Array) -> GString {
        let s: String = hash_floats(nums.as_slice()).to_string();
        GString::from(s.as_str())
    }
}

// ------------------------------------------------------------------ the rng

const SM_A: u64 = 0x94D049BB133111EB;
const SM_B: u64 = 0xBF58476D1CE4E5B9;

/// splitmix64 — the seeding / state-mixing function of the generator.
#[inline(always)]
pub fn splitmix64(state: &mut u64) -> u64 {
    *state = state.wrapping_add(SM_A);
    let mut z: u64 = *state;
    z = (z ^ (z >> 30)).wrapping_mul(SM_B);
    z = (z ^ (z >> 27)).wrapping_mul(SM_A);
    z ^ (z >> 31)
}

/// xoshiro256++: fast, all-64-bit outputs, trivial to serialize (4 words).
pub struct Xo256 {
    s: [u64; 4],
}

impl Xo256 {
    /// Seed with splitmix64: any u64 seed (even 0) gives a full-entropy start.
    pub fn new(seed: u64) -> Self {
        let mut sm = seed;
        let mut s = [0u64; 4];
        for w in s.iter_mut() {
            *w = splitmix64(&mut sm);
        }
        if s.iter().all(|&w| w == 0) {
            s[0] = 1; // the all-zero state is dead: never give it out
        }
        Xo256 { s }
    }

    #[inline(always)]
    pub fn next_u64(&mut self) -> u64 {
        let result = self.s[0].wrapping_add(self.s[3]).rotate_left(23).wrapping_add(self.s[0]);
        let t = self.s[1] << 17;
        self.s[2] ^= self.s[0];
        self.s[3] ^= self.s[1];
        self.s[1] ^= self.s[2];
        self.s[0] ^= self.s[3];
        self.s[2] ^= t;
        self.s[3] = self.s[3].rotate_left(45);
        result
    }

    /// [0, 1) with 53 bits of entropy: (u64 >> 11) * 2^-53 — exact IEEE math.
    #[inline(always)]
    pub fn next_f64(&mut self) -> f64 {
        (self.next_u64() >> 11) as f64 * (1.0 / 9007199254740992.0)
    }

    /// An integer in [0, n) (uniform, no modulo bias: rejection sampling).
    #[inline(always)]
    pub fn below(&mut self, n: u64) -> u64 {
        let zone: u64 = u64::MAX - (u64::MAX % n); // k * n <= u64::MAX holds inside the zone
        loop {
            let v = self.next_u64();
            if v < zone {
                return v % n;
            }
        }
    }
}

#[derive(GodotClass)]
#[class(base=RefCounted, no_init)]  // created by DfRng.make(seed), not by .new()
pub struct DfRng {
    xo: Xo256,
    base: Base<RefCounted>,
}

#[godot_api]
impl DfRng {
    /// `DfRng.make(seed)` — a fresh generator (the same seed = the same stream on every device).
    /// No `self` receiver = a static function on the GDScript side.
    #[func]
    fn make(seed: i64) -> Gd<DfRng> {
        Gd::from_init_fn(|base| DfRng {
            xo: Xo256::new(seed as u64),
            base,
        })
    }

    /// The next raw 64-bit word (as i64: the GDScript side stores state words).
    #[func]
    fn next_word(&mut self) -> i64 {
        self.xo.next_u64() as i64
    }

    /// The next float in [0, 1).
    #[func]
    fn next_f64(&mut self) -> f64 {
        self.xo.next_f64()
    }

    /// An integer in [0, n) (uniform, no modulo bias).
    #[func]
    fn next_below(&mut self, n: i64) -> i64 {
        if n <= 0 {
            return 0;
        }
        self.xo.below(n as u64) as i64
    }

    /// The state as [a, b, c, d] (goes into a snapshot).
    #[func]
    fn state(&self) -> PackedInt64Array {
        PackedInt64Array::from_iter(self.xo.s.iter().map(|&w| w as i64))
    }

    /// Restore from a state array (a snapshot came back).
    #[func]
    fn from_state(&mut self, st: PackedInt64Array) {
        if st.len() < 4 {
            return;
        }
        let s: [u64; 4] = [st[0] as u64, st[1] as u64, st[2] as u64, st[3] as u64];
        if s.iter().all(|&w| w == 0) {
            return; // never accept the dead state
        }
        self.xo.s = s;
    }
}

// ------------------------------------------------------------------ delta core (HostSim v1.2)

/// Chunk-diff of two byte arrays: a bitmap of changed chunks + the concatenated
/// new chunks. Identical semantics live in `net/hs_codec.gd` (the GDScript
/// fallback) — the wire format must stay byte-identical, so the bitmap is
/// LSB-first (bit i of byte i/8) and the last chunk may be partial.
pub fn chunk_diff_core(old: &[u8], new: &[u8], chunk: usize) -> Option<(Vec<u8>, Vec<u8>, usize, usize)> {
    if chunk == 0 || old.len() != new.len() {
        return None;
    }
    let chunks: usize = (new.len() + chunk - 1) / chunk; // ceil
    if chunks == 0 {
        return Some((Vec::new(), Vec::new(), 0, 0));
    }
    let mut bitmap: Vec<u8> = vec![0u8; (chunks + 7) / 8];
    let mut data: Vec<u8> = Vec::new();
    let mut changed: usize = 0;
    for i in 0..chunks {
        let a = i * chunk;
        let b = (a + chunk).min(new.len());
        if old[a..b] != new[a..b] {
            bitmap[i / 8] |= 1u8 << (i % 8);
            data.extend_from_slice(&new[a..b]);
            changed += 1;
        }
    }
    Some((bitmap, data, chunks, changed))
}

/// Inverse of [`chunk_diff_core`]: rebuild `new` from `old` + bitmap + data.
pub fn chunk_apply_core(old: &[u8], bitmap: &[u8], data: &[u8], chunk: usize, total: usize) -> Option<Vec<u8>> {
    if chunk == 0 || old.len() != total {
        return None;
    }
    let chunks: usize = (total + chunk - 1) / chunk;
    let mut out: Vec<u8> = old.to_vec();
    let mut cur: usize = 0;
    for i in 0..chunks {
        let byte = bitmap.get(i / 8).copied().unwrap_or(0);
        if byte & (1u8 << (i % 8)) == 0 {
            continue;
        }
        let a = i * chunk;
        let b = (a + chunk).min(total);
        let len = b - a;
        if cur + len > data.len() {
            return None; // truncated stream: the caller falls back to a keyframe
        }
        out[a..b].copy_from_slice(&data[cur..cur + len]);
        cur += len;
    }
    Some(out)
}

/// Zigzag + LEB128 packing of an integer stream (ids, field masks, deltas).
/// Zigzag folds the sign into the low bit so small negatives stay small.
pub fn zigzag_pack_core(vals: &[i64]) -> Vec<u8> {
    let mut out: Vec<u8> = Vec::with_capacity(vals.len() + 4);
    for &v in vals {
        let z: u64 = ((v << 1) ^ (v >> 63)) as u64;
        let mut w = z;
        loop {
            let byte = (w & 0x7f) as u8;
            w >>= 7;
            if w == 0 {
                out.push(byte);
                break;
            }
            out.push(byte | 0x80);
        }
    }
    out
}

/// Inverse of [`zigzag_pack_core`]. Truncated tails stop silently (the frame
/// checksum on the GDScript side catches real corruption).
pub fn zigzag_unpack_core(data: &[u8]) -> Vec<i64> {
    let mut out: Vec<i64> = Vec::new();
    let mut w: u64 = 0;
    let mut shift: u32 = 0;
    for &b in data {
        w |= ((b & 0x7f) as u64) << shift;
        if b & 0x80 == 0 {
            let z = w;
            let n: i64 = ((z >> 1) as i64) ^ -((z & 1) as i64);
            out.push(n);
            w = 0;
            shift = 0;
        } else {
            shift += 7;
            if shift > 63 {
                w = 0;
                shift = 0;
            }
        }
    }
    out
}

#[derive(GodotClass)]
#[class(base=RefCounted, init)]
pub struct DfDelta {
    base: Base<RefCounted>,
}

#[godot_api]
impl DfDelta {
    /// Chunk-diff of two world arrays. -> {ok, bitmap, data, chunks, changed, bytes}
    /// or {ok: false} when the sizes differ (the caller sends a keyframe instead).
    #[func]
    fn chunk_diff(&self, old: PackedByteArray, new: PackedByteArray, chunk: i32) -> Dictionary<GString, Variant> {
        let mut res: Dictionary<GString, Variant> = Dictionary::new();
        let cd = chunk_diff_core(old.as_slice(), new.as_slice(), chunk.max(1) as usize);
        match cd {
            None => {
                res.set("ok", &false.to_variant());
            }
            Some((bm, data, chunks, changed)) => {
                res.set("ok", &true.to_variant());
                res.set("bitmap", &PackedByteArray::from(&bm[..]).to_variant());
                res.set("data", &PackedByteArray::from(&data[..]).to_variant());
                res.set("chunks", &(chunks as i64).to_variant());
                res.set("changed", &(changed as i64).to_variant());
                res.set("bytes", &(data.len() as i64).to_variant());
            }
        }
        res
    }

    /// Rebuild `new` from `old` + the chunk_diff output. Empty result = bad input.
    #[func]
    fn chunk_apply(&self, old: PackedByteArray, bitmap: PackedByteArray, data: PackedByteArray, chunk: i32, total: i32) -> PackedByteArray {
        match chunk_apply_core(old.as_slice(), bitmap.as_slice(), data.as_slice(), chunk.max(1) as usize, total.max(0) as usize) {
            None => PackedByteArray::new(),
            Some(v) => PackedByteArray::from(&v[..]),
        }
    }

    /// Zigzag+LEB128 of an integer stream (ids, masks). -> {data, count}
    #[func]
    fn pack_ints(&self, vals: PackedInt64Array) -> Dictionary<GString, Variant> {
        let packed = zigzag_pack_core(vals.as_slice());
        let mut res: Dictionary<GString, Variant> = Dictionary::new();
        res.set("data", &PackedByteArray::from(&packed[..]).to_variant());
        res.set("count", &(vals.len() as i64).to_variant());
        res
    }

    /// Inverse of pack_ints.
    #[func]
    fn unpack_ints(&self, data: PackedByteArray) -> PackedInt64Array {
        PackedInt64Array::from_iter(zigzag_unpack_core(data.as_slice()))
    }

    /// 64-bit Fx checksum of a byte frame (the delta header carries it; the
    /// guest drops frames that do not match — transport corruption never applies).
    #[func]
    fn frame_checksum(&self, data: PackedByteArray) -> i64 {
        hash_bytes(data.as_slice()) as i64
    }
}
