//! DroneFlames Reborn — армейские действия на Rust.
//!
//! Движок форсирования рек: замедление в воде, запрет входа в море,
//! прерывание огнём, выбор места переправы, детерминированные слоты.
//! Все расчёты детерминированы (одинаковые входы -> одинаковые выходы на всех
//! пирах), float-математика совпадает с GDScript (Vector2 = f32, как в Godot).

use godot::init::*;
use godot::prelude::*;

/// dfnet — детерминированные примитивы сетевой синхронизации (локаcтеп):
/// DfHash — Fx-хэш состояния с канонизацией ±0.0/NaN; DfRng — xoshiro256++
/// со splitmix64-seeding; состояние = 4 слова (снапшот).
mod dfnet;
pub use dfnet::{
    chunk_apply_core, chunk_diff_core, hash_bytes, hash_floats, zigzag_pack_core, zigzag_unpack_core, Xo256,
};

struct DfArmyExt;
#[gdextension(entry_symbol = dfarmy_init)]
unsafe impl ExtensionLibrary for DfArmyExt {}

/// Коды terrain-сетки (заполняется GDScript-ом при старте мира / смене версии навигации):
const CODE_LAND: u8 = 0; // суша или мост — обычная скорость
const CODE_FORD: u8 = 1; // река (Biome.RIVER) — проходимо вброд
const CODE_SEA: u8 = 2; // море/озеро — непроходимо для колёсных/гусеничных

/// Множители скорости в воде: вброд пехота идёт быстрее, техника заметно медленнее.
const FORD_SPD_FOOT: f32 = 0.38;
const FORD_SPD_VEH: f32 = 0.24;

#[derive(GodotClass)]
#[class(base=Object, init)]
struct DFArmy {
    w: i32,
    h: i32,
    cell: f32,
    grid: Vec<u8>,
}

#[godot_api]
impl DFArmy {
    fn init(_base: Base<Object>) -> Self {
        DFArmy { w: 0, h: 0, cell: 4.0, grid: Vec::new() }
    }

    /// Загрузить codes-сетку мира: w*h байт, CODE_LAND / CODE_FORD / CODE_SEA.
    #[func]
    fn grid_set(&mut self, w: i32, h: i32, cell: f32, codes: PackedByteArray) {
        self.w = w.max(0);
        self.h = h.max(0);
        self.cell = if cell > 0.0 { cell } else { 4.0 };
        let n = (self.w * self.h).max(0) as usize;
        let mut g = vec![CODE_LAND; n];
        let src = codes.as_slice();
        let take = src.len().min(n);
        g[..take].copy_from_slice(&src[..take]);
        self.grid = g;
    }

    /// Загрузить сетку прямо из WorldData (нулевое копирование biome + flags):
    /// biome > river_id -> CODE_LAND; biome == river_id и без моста -> CODE_FORD;
    /// прочая вода без моста -> CODE_SEA; клетки мостов -> CODE_LAND.
    #[func]
    fn grid_set_biome(&mut self, w: i32, h: i32, cell: f32, biome: PackedByteArray, flags: PackedByteArray, river_id: i32, flag_bridge: i32) {
        self.w = w.max(0);
        self.h = h.max(0);
        self.cell = if cell > 0.0 { cell } else { 4.0 };
        let n = (self.w * self.h).max(0) as usize;
        let mut g = vec![CODE_LAND; n];
        let bio = biome.as_slice();
        let flg = flags.as_slice();
        let river = river_id.max(0) as u8;
        let fb = flag_bridge as u8;
        let take = bio.len().min(n);
        let ftake = flg.len().min(take);
        for i in 0..take {
            let b = bio[i];
            if b > river {
                continue; // суша
            }
            let mut code = CODE_SEA;
            if b == river {
                code = CODE_FORD;
            }
            if i < ftake && (flg[i] & fb) != 0 {
                code = CODE_LAND; // мост
            }
            g[i] = code;
        }
        self.grid = g;
    }

    /// Частичное обновление клеток (мосты построены/разрушены): idx PackedInt32Array, code байты.
    #[func]
    fn grid_patch(&mut self, idx: PackedInt32Array, codes: PackedByteArray) {
        let ii = idx.as_slice();
        let cc = codes.as_slice();
        let n = ii.len().min(cc.len());
        for k in 0..n {
            let i = ii[k] as usize;
            if i < self.grid.len() {
                self.grid[i] = cc[k];
            }
        }
    }

    fn code_at(&self, x: i32, y: i32) -> u8 {
        if x < 0 || y < 0 || x >= self.w || y >= self.h {
            return CODE_SEA;
        }
        self.grid[(y * self.w + x) as usize]
    }

    fn code_at_px(&self, p: Vector2) -> u8 {
        if self.cell <= 0.0 || !p.is_finite() {
            return CODE_LAND;
        }
        let x = (p.x / self.cell).floor() as i32;
        let y = (p.y / self.cell).floor() as i32;
        self.code_at(x, y)
    }

    /// Ширина водной полосы (px) в точке: максимум пробега по четырём осям.
    fn band_width_px(&self, p: Vector2) -> f32 {
        let cx = (p.x / self.cell).floor() as i32;
        let cy = (p.y / self.cell).floor() as i32;
        let mut best = 0.0_f32;
        for d in [Vector2::new(1.0, 0.0), Vector2::new(-1.0, 0.0), Vector2::new(0.0, 1.0), Vector2::new(0.0, -1.0)] {
            let mut run: i32 = 0;
            let mut qx = cx;
            let mut qy = cy;
            while self.code_at(qx, qy) == CODE_FORD && run < 96 {
                qx += d.x as i32;
                qy += d.y as i32;
                run += 1;
            }
            if run as f32 > best {
                best = run as f32;
            }
        }
        best * self.cell
    }

    /// Выбор места форсирования: узкая полоса реки рядом с линией «от -> цель».
    /// Перебор клеток детерминирован (по строкам), оценка = ширина + штраф расстояния.
    #[func]
    fn ford_pick(&self, from: Vector2, goal: Vector2, radius: f32) -> Dictionary<GString, Variant> {
        let mut res: Dictionary<GString, Variant> = Dictionary::new();
        if self.grid.is_empty() || self.cell <= 0.0 {
            res.set("ok", &false.to_variant());
            return res;
        }
        let line = goal - from;
        let len2 = line.x * line.x + line.y * line.y;
        let mut best_score = f32::INFINITY;
        let mut best_site = Vector2::INF;
        for y in 0..self.h {
            for x in 0..self.w {
                if self.code_at(x, y) != CODE_FORD {
                    continue;
                }
                let p = Vector2::new((x as f32 + 0.5) * self.cell, (y as f32 + 0.5) * self.cell);
                let mut t = if len2 > 0.0 { (p - from).dot(line) / len2 } else { 0.0 };
                if t < 0.0 {
                    t = 0.0;
                }
                if t > 1.0 {
                    t = 1.0;
                }
                let proj = from + line * t;
                let dl = p.distance_to(proj);
                if dl > radius {
                    continue;
                }
                let wpx = self.band_width_px(p);
                let score = wpx * 1.6 + dl + x as f32 * 0.013 + y as f32 * 0.007;
                if score < best_score {
                    best_score = score;
                    best_site = p;
                }
            }
        }
        res.set("ok", &best_site.is_finite().to_variant());
        res.set("site", &best_site.to_variant());
        res.set("width", &self.band_width_px(best_site).to_variant());
        res
    }

    /// Степпинг пачки юнитов вдоль их путей с учётом форсирования.
    ///
    /// pos/pi/spd/ford/veh/int/back — по элементу на юнита. paths — плоский список
    /// точек путей, starts[i] — индекс первой точки пути юнита i (путь юнита i:
    /// paths[starts[i]..starts[i+1]]).
    ///
    /// Возврат: {pos, pi, water, arrived, blocked} — новые позиции, число съеденных
    /// точек пути, «в воде», «дошёл», «упёрся в непроходимое (море)».
    #[func]
    fn step(
        &self,
        dt: f32,
        pos: PackedVector2Array,
        paths: PackedVector2Array,
        starts: PackedInt32Array,
        pi: PackedInt32Array,
        spd: PackedFloat32Array,
        ford: PackedByteArray,
        veh: PackedByteArray,
        interrupt: PackedByteArray,
        back_out: PackedByteArray,
    ) -> Dictionary<GString, Variant> {
        let mut res: Dictionary<GString, Variant> = Dictionary::new();
        let n = pos.len().min(pi.len()).min(spd.len()).min(starts.len().saturating_sub(1));
        let mut new_pos = PackedVector2Array::new();
        let mut new_pi = PackedInt32Array::new();
        let mut water = PackedByteArray::new();
        let mut arrived = PackedByteArray::new();
        let mut blocked = PackedByteArray::new();
        new_pos.resize(n);
        new_pi.resize(n);
        water.resize(n);
        arrived.resize(n);
        blocked.resize(n);
        let pth = paths.as_slice();
        let starts_s = starts.as_slice();
        let ford_s = ford.as_slice();
        let veh_s = veh.as_slice();
        let int_s = interrupt.as_slice();
        let back_s = back_out.as_slice();
        let mut pos_v: Vec<Vector2> = pos.as_slice().to_vec();
        let pi_v: Vec<i32> = pi.as_slice().to_vec();
        let spd_v: Vec<f32> = spd.as_slice().to_vec();

        for i in 0..n {
            let mut p = pos_v[i];
            let mut idx = pi_v[i];
            let s0 = starts_s[i] as usize;
            let s1 = starts_s[i + 1] as usize;
            let ford_on = ford_s.get(i).copied().unwrap_or(0) != 0;
            let is_veh = veh_s.get(i).copied().unwrap_or(0) != 0;
            let hit = int_s.get(i).copied().unwrap_or(0) != 0;
            let retreat = back_s.get(i).copied().unwrap_or(0) != 0;
            let base = spd_v[i].max(0.0);

            let in_water_now = self.code_at_px(p) == CODE_FORD;
            if in_water_now && hit {
                // Юнит в воде под огнём: замирает (GDScript уведёт его на свой берег).
                new_pos[i] = p;
                new_pi[i] = idx;
                water[i] = 1;
                continue;
            }

            let fmul = if ford_on {
                if is_veh { FORD_SPD_VEH } else { FORD_SPD_FOOT }
            } else {
                1.0
            };

            // Бюджет — «сухие» пиксели кадра; в воде каждый пиксель стоит 1/fmul бюджета.
            let mut budget = dt * base;
            let mut in_water = false;
            let mut gave_up = false;
            let mut guard: u32 = 0;
            while budget > 0.0 {
                guard += 1;
                if guard > 4096 {
                    break;
                }
                let rem = (s1 - s0) as i32 - idx;
                if rem <= 0 {
                    break;
                }
                let q = pth[s0 + idx as usize];
                let to = q - p;
                let dist = (to.x * to.x + to.y * to.y).sqrt().max(1e-6);
                let nxt = p + to * ((budget.min(dist)) / dist);
                let code_next = self.code_at_px(nxt);
                let code_now = self.code_at_px(p);
                if code_next == CODE_SEA && code_now != CODE_SEA && !retreat {
                    // Море вперёди — стоп, пусть GDScript перестраивает маршрут.
                    gave_up = true;
                    break;
                }
                let wet = code_next == CODE_FORD || code_now == CODE_FORD;
                if wet {
                    in_water = true;
                }
                let fm = if wet { fmul } else { 1.0 };
                let step = budget * fm;
                if dist <= step + 0.5 {
                    p = q;
                    idx += 1;
                    budget -= dist / fm;
                } else {
                    p = nxt;
                    budget = 0.0;
                }
            }
            // Подавление численного дрейфа: привязка к сетке 1/64 px (детерминизм на пирах).
            p.x = (p.x * 64.0).round() / 64.0;
            p.y = (p.y * 64.0).round() / 64.0;
            new_pos[i] = p;
            new_pi[i] = idx;
            water[i] = if in_water { 1 } else { 0 };
            arrived[i] = if idx >= (s1 - s0) as i32 { 1 } else { 0 };
            blocked[i] = if gave_up { 1 } else { 0 };
        }
        res.set("pos", &new_pos.to_variant());
        res.set("pi", &new_pi.to_variant());
        res.set("water", &water.to_variant());
        res.set("arrived", &arrived.to_variant());
        res.set("blocked", &blocked.to_variant());
        res
    }

    /// Детерминированное смещение слота построения (замена GDScript-формул).
    #[func]
    fn slot_of(&self, k: i32, dx: f32, dy: f32) -> Vector2 {
        Vector2::new(((k % 3) - 1) as f32 * dx, (k / 3) as f32 * dy)
    }

    /// Reborn v1.1.5: однопроходная группировка юнитов по казармам для
    /// operations._tick. Заменяет три полных прохода O(операций × юнитов) на
    /// один проход O(юнитов): per-home списки индексов юнитов (участники
    /// операций op_on, свободные без поста/подкрепления, все живые наземные),
    /// сумма hp окопников без приказа и центры масс/суммы hp.
    /// Порядок индексов внутри каждого списка — возрастание (детерминировано).
    #[func]
    fn tick_groups(
        &self,
        unit_home: PackedInt32Array,
        unit_alive: PackedByteArray,
        unit_ground: PackedByteArray,
        unit_op_on: PackedByteArray,
        unit_post: PackedByteArray,
        unit_reinf: PackedByteArray,
        unit_hp: PackedFloat32Array,
        unit_px: PackedFloat32Array,
        unit_py: PackedFloat32Array,
    ) -> Dictionary<GString, Variant> {
        let n = unit_home.len();
        let home = unit_home.as_slice();
        let alive = unit_alive.as_slice();
        let ground = unit_ground.as_slice();
        let op_on = unit_op_on.as_slice();
        let post = unit_post.as_slice();
        let reinf = unit_reinf.as_slice();
        let hp = unit_hp.as_slice();
        let px = unit_px.as_slice();
        let py = unit_py.as_slice();

        let mut members_op_on: std::collections::BTreeMap<i32, Vec<i32>> = std::collections::BTreeMap::new();
        let mut members_free: std::collections::BTreeMap<i32, Vec<i32>> = std::collections::BTreeMap::new();
        let mut members_all: std::collections::BTreeMap<i32, Vec<i32>> = std::collections::BTreeMap::new();
        let mut post_hp: std::collections::BTreeMap<i32, f32> = std::collections::BTreeMap::new();
        let mut cen_x: std::collections::BTreeMap<i32, f32> = std::collections::BTreeMap::new();
        let mut cen_y: std::collections::BTreeMap<i32, f32> = std::collections::BTreeMap::new();
        let mut sum_hp: std::collections::BTreeMap<i32, f32> = std::collections::BTreeMap::new();

        for i in 0..n {
            let hid = home[i];
            if hid < 0 {
                continue;
            }
            let ui = i as usize;
            if alive.get(ui).copied().unwrap_or(0) == 0 || ground.get(ui).copied().unwrap_or(0) == 0 {
                continue;
            }
            let has_post = post.get(ui).copied().unwrap_or(0) != 0;
            let in_op = op_on.get(ui).copied().unwrap_or(0) != 0;
            members_all.entry(hid).or_default().push(i as i32);
            if in_op {
                members_op_on.entry(hid).or_default().push(i as i32);
                *cen_x.entry(hid).or_insert(0.0) += px.get(ui).copied().unwrap_or(0.0);
                *cen_y.entry(hid).or_insert(0.0) += py.get(ui).copied().unwrap_or(0.0);
                *sum_hp.entry(hid).or_insert(0.0) += hp.get(ui).copied().unwrap_or(0.0);
            } else if has_post {
                *post_hp.entry(hid).or_insert(0.0) += hp.get(ui).copied().unwrap_or(0.0);
            }
            if !has_post && reinf.get(ui).copied().unwrap_or(0) == 0 {
                members_free.entry(hid).or_default().push(i as i32);
            }
        }

        let mut res: Dictionary<GString, Variant> = Dictionary::new();
        res.set("members_op_on", &Self::pack_map(&members_op_on).to_variant());
        res.set("members_free", &Self::pack_map(&members_free).to_variant());
        res.set("members_all", &Self::pack_map(&members_all).to_variant());
        res.set("post_hp", &pack_f32_map(&post_hp).to_variant());
        res.set("cen_x", &pack_f32_map(&cen_x).to_variant());
        res.set("cen_y", &pack_f32_map(&cen_y).to_variant());
        res.set("sum_hp", &pack_f32_map(&sum_hp).to_variant());
        res
    }

    fn pack_map(m: &std::collections::BTreeMap<i32, Vec<i32>>) -> Dictionary<i32, Variant> {
        let mut d: Dictionary<i32, Variant> = Dictionary::new();
        for (k, v) in m {
            let mut p = PackedInt32Array::new();
            for &x in v {
                p.push(x);
            }
            d.set(*k, &p.to_variant());
        }
        d
    }

    /// Диагностика: GDScript узнаёт, что движок загружен.
    #[func]
    fn version(&self) -> GString {
        GString::from("dfarmy 1.1.6")
    }

    /// v1.3.0 — жадный план массовых улучшений (паритет game/bulk_infrastructure.gd
    /// plan(), апстрим 0.41.4 «Улучшить все»). См. bulk_plan_core.
    #[func]
    fn bulk_plan(cost_flat: PackedInt64Array, cost_off: PackedInt32Array, budgets: PackedInt64Array) -> PackedInt64Array {
        let out = bulk_plan_core(cost_flat.as_slice(), cost_off.as_slice(), budgets.as_slice());
        let mut p = PackedInt64Array::new();
        for v in &out {
            p.push(*v);
        }
        p
    }
}

/// Чистое ядро bulk_plan: строки стоимостей cost_flat[off[i]..off[i+1]] в
/// фиксированном порядке ресурсов, budgets[k] — остаток бюджета ресурса k.
/// Жадно выбирает объекты в порядке следования, пропуская недоступные
/// (нехватка бюджета или отрицательная стоимость) и строки неширины k.
/// Возвращает [n] флагов выбора (0/1) + [k] суммарных трат по ресурсам.
/// Детерминировано: одинаковые входы -> одинаковые выходы на всех пирах.
pub fn bulk_plan_core(flat: &[i64], off: &[i32], budgets: &[i64]) -> Vec<i64> {
    let k = budgets.len();
    let n = if off.is_empty() { 0 } else { off.len() - 1 };
    let mut budget: Vec<i64> = budgets.to_vec();
    let mut totals: Vec<i64> = vec![0i64; k];
    let mut flags: Vec<i64> = vec![0i64; n];
    for i in 0..n {
        let a = off[i] as usize;
        let b = off[i + 1] as usize;
        if b - a != k {
            continue; // строка не совпадает по ширине — пропускаем (битый ввод)
        }
        let mut ok = true;
        for t in 0..k {
            let c = flat[a + t];
            if c < 0 || budget[t] < c {
                ok = false;
                break;
            }
        }
        if !ok {
            continue;
        }
        for t in 0..k {
            let c = flat[a + t];
            budget[t] -= c;
            totals[t] += c;
        }
        flags[i] = 1;
    }
    flags.extend(totals);
    flags
}

fn pack_f32_map(m: &std::collections::BTreeMap<i32, f32>) -> Dictionary<i32, Variant> {
    let mut d: Dictionary<i32, Variant> = Dictionary::new();
    for (k, v) in m {
        d.set(*k, &v.to_variant());
    }
    d
}
