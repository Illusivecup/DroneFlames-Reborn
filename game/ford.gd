class_name FordCore
extends RefCounted

## Движок форсирования рек. Тяжёлая математика — GDExtension DFArmy (Rust);
## если библиотека не загрузилась, всё то же считается здесь (детерминированно,
## теми же формулами). Армия с включённым форсированием: юниты идут через
## клетки реки (Biome.RIVER) замедленно, море непроходимо; огонь по юнитам в
## воде останавливает переправу (army.ford_halt) до затишья.

const CODE_LAND: int = 0
const CODE_FORD: int = 1
const CODE_SEA: int = 2

const FORD_SPD_FOOT: float = 0.38
const FORD_SPD_VEH: float = 0.24
const FORD_HOLD_S: float = 8.0        # пауза форсирования после огня
const FORD_CALM_S: float = 4.0        # сколько нужно затишья, чтобы продолжить
const FORD_SAY_CD: float = 20.0       # не спамим сообщениями об остановке

static var _core: Object = null
static var _core_tried: bool = false

## Есть ли Rust-движок (DFArmy из addons/dfarmy).
static func has_rust() -> bool:
        if not _core_tried:
                _core_tried = true
                if ClassDB.class_exists("DFArmy"):
                        _core = ClassDB.instantiate("DFArmy")
        return _core != null


static func core() -> Object:
        if has_rust():
                return _core
        return null


## Загрузить terrain-сетку мира в Rust-движок (один раз при постройке мира).
static func grid_load(gw: GameWorld) -> void:
        var c: Object = core()
        if c == null or gw == null or gw.data == null:
                return
        c.call("grid_set_biome", gw.data.w, gw.data.h, float(GameWorld.CELL), gw.data.biome, gw.data.flags, Biome.RIVER, WorldData.F_BRIDGE)


## Патч клеток после постройки/разрушения моста (idx — линейные индексы клеток).
static func grid_patch(idx: PackedInt32Array, codes: PackedByteArray) -> void:
        var c: Object = core()
        if c == null or idx.is_empty():
                return
        c.call("grid_patch", idx, codes)


## Точка на берегу для выхода из воды/отступления: ближайшая суша против хода к цели.
static func bank_point(gw: GameWorld, u: Unit, goal: Vector2) -> Vector2:
        var away: Vector2 = (u.pos - goal)
        if away.length() < 1.0:
                away = Vector2(0.0, 1.0)
        else:
                away = away.normalized()
        var back: Vector2 = gw.econ.land_point(u.pos + away * 40.0, 12)
        if ground_code(gw, back) == CODE_LAND and back.distance_to(u.pos) <= 52.0:
                return back
        # Шаг 2: перебор восьми направлений — ближайшая суша (детерминированный порядок).
        for k in 8:
                var ang: float = TAU * float(k) / 8.0
                var p: Vector2 = gw.econ.land_point(u.pos + Vector2.from_angle(ang) * 40.0, 12)
                if ground_code(gw, p) == CODE_LAND and p.distance_to(u.pos) <= 52.0:
                        return p
        return Vector2.INF


## Код клетки в точке: без Rust — по биомам (те же правила).
static func ground_code(gw: GameWorld, p: Vector2) -> int:
        if gw == null or gw.data == null:
                return CODE_LAND
        var d: WorldData = gw.data
        var cx: int = floori(p.x / GameWorld.CELL)
        var cy: int = floori(p.y / GameWorld.CELL)
        if not d.inside(cx, cy):
                return CODE_SEA
        var i: int = cy * d.w + cx
        if (d.flags[i] & WorldData.F_BRIDGE) != 0:
                return CODE_LAND
        var b: int = d.biome[i]
        if b > Biome.RIVER:
                return CODE_LAND
        if b == Biome.RIVER:
                return CODE_FORD
        return CODE_SEA


## Юнит стоит в реке (вброд).
static func in_river(gw: GameWorld, u: Unit) -> bool:
        return ground_code(gw, u.pos) == CODE_FORD


## Юнит годен для батч-степпинга Rust-движка в этом кадре. Дешёвые проверки:
## армии с включённым форсированием всегда ведёт Rust (сухие пути он проходит
## той же математикой); юниты в воде — отдельно (для стран с выключенным
## форсированием отбор по дешёвому флагу ford_bank, а не по осмотру клеток).
static func batchable(gw: GameWorld, u: Unit) -> bool:
        if u == null or not u.alive() or u.type == Unit.Type.FPV or u.reinf != 0:
                return false
        if u.home != null and gw.army.ford_on(u.home):
                return true
        return u.ford_bank.is_finite() and in_river(gw, u)


## Батч-степпинг пачки юнитов. Возвращает Dictionary {pi:[], water:[], arrived:[], blocked:[]}
## или пустой Dictionary, если Rust-движка нет (гость без lib вызывает GDScript-путь сам).
static func batch_step(gw: GameWorld, batch: Array, dt: float) -> Dictionary:
        var c: Object = core()
        if c == null or batch.is_empty():
                return {}
        var n: int = batch.size()
        var pos: PackedVector2Array = PackedVector2Array()
        var pi: PackedInt32Array = PackedInt32Array()
        var spd: PackedFloat32Array = PackedFloat32Array()
        var ford: PackedByteArray = PackedByteArray()
        var veh: PackedByteArray = PackedByteArray()
        var interrupt: PackedByteArray = PackedByteArray()
        var back_out: PackedByteArray = PackedByteArray()
        var starts: PackedInt32Array = PackedInt32Array()
        var paths: PackedVector2Array = PackedVector2Array()
        pos.resize(n)
        pi.resize(n)
        spd.resize(n)
        ford.resize(n)
        veh.resize(n)
        interrupt.resize(n)
        back_out.resize(n)
        starts.resize(n + 1)
        starts[0] = 0
        var now: float = gw.game_time
        var halt: Dictionary = gw.army.ford_halt
        for k in n:
                var u: Unit = batch[k]
                pos[k] = u.pos
                pi[k] = u.pi
                var s: float = float(Army.SPEC[u.type]["speed"])
                if u.reinf == 2 and u.reinf_v > 0.0:
                        s = minf(s, u.reinf_v)
                var cn: Country = gw.country_by_id(u.country_id)
                if cn != null and cn.food <= 0:
                        s *= 0.6
                var home: Facility = u.home
                var halted: bool = home != null and halt.has(home.id) and now < float(halt[home.id])
                var wet: bool = in_river(gw, u)
                if halted and wet:
                        # Форсирование остановлено огнём: юнит в воде уходит на свой берег.
                        # Путь подменяется одной точкой (pi сбрасывается в 0), настоящий pi
                        # не трогаем — GDScript применит только позицию.
                        var bk: Vector2 = u.ford_bank
                        if bk.is_finite():
                                paths.append(bk)
                        else:
                                paths.append(u.pos)
                        back_out[k] = 1
                        pi[k] = 0
                elif halted:
                        # На берегу при паузе: стоит на месте (путь пустой).
                        paths.append(u.pos)
                        back_out[k] = 2
                        pi[k] = 0
                else:
                        for j in range(u.pi, u.path.size()):
                                paths.append(u.path[j])
                spd[k] = s
                ford[k] = 1 if (home != null and gw.army.ford_on(home)) else 0
                veh[k] = 1 if u.vehicle() else 0
                interrupt[k] = 1 if now - u.hit_t < 3.0 else 0
                starts[k + 1] = paths.size()
        var res: Dictionary = c.call("step", dt, pos, paths, starts, pi, spd, ford, veh, interrupt, back_out)
        res["back"] = back_out
        return res


## GDScript-фолбэк: побитовая копия Rust-степпинга для одного юнита.
## Reborn: раньше фолбэк расходился с нативом (не было ford_halt-отступа,
## флаг скорости брался как u.home.ford вместо армейского ford_on(home),
## не было привязки к сетке 1/64 px) — пиры с нативом и без него
## расходились позициями. Теперь: та же сборка пути, что в batch_step,
## тот же бюджет-цикл, та же сетка — детерминизм между пирами.
static func step_one_gd(gw: GameWorld, u: Unit, dt: float) -> Dictionary:
        var home: Facility = u.home
        var halt: Dictionary = gw.army.ford_halt
        var now: float = gw.game_time
        var halted: bool = home != null and halt.has(home.id) and now < float(halt[home.id])
        var wet_now: bool = in_river(gw, u)
        # — сборка пути как в batch_step —
        var pts: = PackedVector2Array()
        var idx: int = u.pi
        var back: int = 0
        if halted and wet_now:
                # Форсирование остановлено огнём: в воде уходим на свой берег.
                var bk: Vector2 = u.ford_bank
                if not bk.is_finite():
                        bk = bank_point(gw, u, u.path[u.path.size() - 1] if not u.path.is_empty() else u.pos)
                pts.append(bk if bk.is_finite() else u.pos)
                back = 1
                idx = 0
        elif halted:
                # На берегу при паузе: стоит на месте (путь из своей позиции).
                pts.append(u.pos)
                back = 2
                idx = 0
        else:
                for j in range(u.pi, u.path.size()):
                        pts.append(u.path[j])
        # — бюджет-цикл как в Rust step() —
        var p: Vector2 = u.pos
        var ford_flag: bool = home != null and gw.army.ford_on(home)
        var fmul: float = (FORD_SPD_VEH if u.vehicle() else FORD_SPD_FOOT) if ford_flag else 1.0
        var base: float = float(Army.SPEC[u.type]["speed"])
        if u.reinf == 2 and u.reinf_v > 0.0:
                base = minf(base, u.reinf_v)
        var cn: Country = gw.country_by_id(u.country_id)
        if cn != null and cn.food <= 0:
                base *= 0.6
        var budget: float = dt * base
        var in_water: bool = false
        var gave_up: bool = false
        if ground_code(gw, p) == CODE_FORD and now - u.hit_t < 3.0:
                # В воде под огнём: замирает (как in_water_now && hit в Rust step()).
                in_water = true
        else:
                var guard: int = 0
                while budget > 0.0 and guard < 4096:
                        guard += 1
                        if idx >= pts.size():
                                break
                        var q: Vector2 = pts[idx]
                        var to: Vector2 = q - p
                        var dist: float = maxf(to.length(), 1e-6)
                        var nxt: Vector2 = p + to * (minf(budget, dist) / dist)
                        var code_n: int = ground_code(gw, nxt)
                        var code_p: int = ground_code(gw, p)
                        if code_n == CODE_SEA and code_p != CODE_SEA and back == 0:
                                # Море впереди — стоп, пусть армия перестраивает маршрут.
                                gave_up = true
                                break
                        var wet: bool = code_n == CODE_FORD or code_p == CODE_FORD
                        if wet:
                                in_water = true
                        var fm: float = fmul if wet else 1.0
                        var step: float = budget * fm
                        if dist <= step + 0.5:
                                p = q
                                idx += 1
                                budget -= dist / fm
                        else:
                                p = nxt
                                budget = 0.0
        # Подавление численного дрейфа: привязка к сетке 1/64 px (как в Rust).
        p.x = roundf(p.x * 64.0) / 64.0
        p.y = roundf(p.y * 64.0) / 64.0
        return {
                "pi": idx, "water": in_water, "arrived": idx >= pts.size(),
                "blocked": gave_up, "back": back, "pos": p,
        }


## Выбор места переправы (Rust; фолбэк — перебор клеток реки рядом с линией).
static func pick_site(gw: GameWorld, from: Vector2, goal: Vector2, radius: float) -> Vector2:
        var c: Object = core()
        if c != null:
                var r: Dictionary = c.call("ford_pick", from, goal, radius)
                if bool(r.get("ok", false)):
                        return r.get("site", Vector2.INF)
                return Vector2.INF
        # Фолбэк: скан клеток реки вдоль линии (шаг 8 клеток, детерминированный).
        var d: WorldData = gw.data
        var best: Vector2 = Vector2.INF
        var best_w: int = 999999
        var n: int = maxi(1, int(from.distance_to(goal) / (GameWorld.CELL * 8.0)))
        for k in n + 1:
                var p: Vector2 = from.lerp(goal, float(k) / float(n))
                var cx: int = floori(p.x / GameWorld.CELL)
                var cy: int = floori(p.y / GameWorld.CELL)
                for oy in range(-6, 7):
                        for ox in range(-6, 7):
                                var x: int = cx + ox
                                var y: int = cy + oy
                                if not d.inside(x, y):
                                        continue
                                var i: int = y * d.w + x
                                if d.biome[i] != Biome.RIVER or (d.flags[i] & WorldData.F_BRIDGE) != 0:
                                        continue
                                var w2: int = 0
                                for dir2 in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
                                        var run: int = 0
                                        var qx: int = x
                                        var qy: int = y
                                        while d.inside(qx, qy) and d.biome[qy * d.w + qx] == Biome.RIVER and run < 64:
                                                qx += dir2.x
                                                qy += dir2.y
                                                run += 1
                                        w2 = maxi(w2, run)
                                if w2 < best_w:
                                        best_w = w2
                                        best = Vector2(x * GameWorld.CELL + 2, y * GameWorld.CELL + 2)
        return best
