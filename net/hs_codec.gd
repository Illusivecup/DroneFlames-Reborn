class_name HsCodec
extends RefCounted

## HostSim codec (docs/HOSTSIM.md): binary state deltas host -> guests.
##
## The host builds a delta every NetConfig.HS_DELTA_EVERY turns; guests apply it
## into their (non-simulating) GameWorld. Entity fields are picked up by
## reflection — the same script-variable walk Save uses — so new game fields
## flow without codec edits, and anything a delta misses self-heals at the next
## keyframe (Save.net_snapshot, every NetConfig.HS_KEY_TURNS turns).
##
## Wire layout (little-endian, StreamPeerBuffer):
##   'HSD1' u32 | seq u32 | game_time f64 | speed u8
##   SEC_DEL  per kind: u16 count, u32 ids        (U/D/M/A/S erase, Y/F/C null in place)
##   SEC_ENT  per kind: u16 count; per entity u32 id, u64 field mask, changed values via put_var
##   SEC_MAP  owners chunk-diff: u32 total, u32 bitmap len, bitmap, u32 data len, data
##   SEC_OBJ  obj_state chunk-diff (same layout)
##   SEC_FX   u16 count, put_var event dicts
##   SEC_SYS  u16 count; per entry: put_var "path.field", put_var deep-stripped value
##   END u8
##
## The big arrays go through the Rust chunk-diff (DfDelta in dfarmy) when the
## extension is loaded; the GDScript fallback below is byte-identical (LSB-first
## bitmap), so the wire format does not depend on the build.

const MAGIC: int = 0x48534431  # 'HSD1'
const SEC_DEL: int = 1
const SEC_ENT: int = 2
const SEC_MAP: int = 3
const SEC_OBJ: int = 4
const SEC_FX: int = 5
const SEC_SYS: int = 6
const SEC_END: int = 0

## Delta kinds in wire order. U/D/M/A/S are id-addressed append lists, Y/F/C are
## index-addressed (cities[id] / facilities[id] / countries[id-1]).
const KIND_TAGS: Array[String] = ["U", "D", "M", "A", "S", "Y", "F", "C"]
const ENT_SCRIPT: Dictionary = {
        "U": "res://game/unit.gd", "D": "res://game/drone.gd", "M": "res://game/missile.gd",
        "A": "res://game/aircraft.gd", "S": "res://game/ship.gd", "Y": "res://game/city.gd",
        "F": "res://game/facility.gd", "C": "res://game/country.gd",
}
## Moving entities: their pos (or t for missiles) is interpolated on the guest.
const POS_FIELD: Dictionary = {"U": "pos", "D": "pos", "M": "t", "A": "pos", "S": "pos"}
## Non-entity subsystem state synced at a slower cadence (SYS section). Only
## primitive/ref-dict fields; anything else is a keyframe concern.
const SYS_FIELDS: Dictionary = {
        "diplo": ["rel", "since", "truce_until", "opinion", "embargo", "treaties", "offers",
                "t_offers", "demands", "war_goals", "coalition", "passage", "war_by", "good_since",
                "peace_t"],
        "econ": ["scarce", "scarce_zone", "auto_sub"],
        ## v1.3.3: the alliances (membership + pending invites) used to ride ONLY the
        ## full keyframe — every delta skipped them, so a guest's alliance invites and
        ## roster were minutes (or a reconnect) behind the host. Nested paths are
        ## supported by _sys_obj below ("a.b" = gw.a.b).
        "diplo.ally": ["list", "offers", "_oid"],
}

const MASK_BITS: int = 64
## Fields the delta never carries: live node handles (fx sprite pools, flag nodes)
## and save-special structures. They exist on the guest from the world build /
## keyframes; the sim re-fills them on the host only.
const SKIP_FIELDS: Dictionary = {
        "F": ["fx"], "Y": ["flag_node", "visited"],
}
## Sim-transient fields every delta skips on every kind: pathing buffers and
## combat cooldowns/timers change nearly every tick and mean nothing to a guest
## that does not simulate. A keyframe refreshes them; the sim refills them.
const SKIP_ANY: Array[String] = [
        "path", "pi", "taxi", "route", "fire_cd", "fpv_cd", "rpg_cd", "gren_cd", "jam_t",
        "dead_t", "still_t", "supp", "hit_t", "salvo", "salvo_t", "no_post_until",
        "trail_acc", "boost_t", "rail_s", "wait_t", "service_t", "spot", "dist",
]

## Host caches (one running match per process; reset via host_reset()).
static var _last_ent: Dictionary = {}  # tag -> {id: Array of normalized values}
static var _last_sys: Dictionary = {}  # "path.field" -> int hash
static var _last_map: PackedByteArray = PackedByteArray()
static var _last_obj_a: Dictionary = {}  # obj array name -> last sent bytes (see OBJ_ARRAYS)
static var _last_obj_size: int = -1
## Guest side: the object count whose ids are already registered into the render
## chunks (see guest_seeded / _obj_register). -1 = unknown (before the first frame).
static var _obj_reg_n: int = -1

static var _props_c: Dictionary = {}  # Script -> PackedStringArray of script variables

static var rust_ok: bool = ClassDB.class_exists("DfDelta")


# ------------------------------------------------------------------ host side

static func host_reset() -> void:
        _last_ent.clear()
        _last_sys.clear()
        _last_map = PackedByteArray()
        _last_obj_a.clear()
        _last_obj_size = -1
        _obj_reg_n = -1


static func _props(o: Object) -> PackedStringArray:
        var s: Script = o.get_script()
        if _props_c.has(s):
                return _props_c[s]
        var out := PackedStringArray()
        for p: Dictionary in o.get_property_list():
                if int(p["usage"]) & PROPERTY_USAGE_SCRIPT_VARIABLE:
                        var n: String = String(p["name"])
                        if n.begins_with("$"):
                                continue
                        out.append(n)
        _props_c[s] = out
        return out


## A value as it travels the wire: entity objects (including ones nested in
## arrays/dictionaries) become resolvable refs, everything the wire cannot
## carry becomes null (the field bit is dropped). Mirrors Save.enc semantics.
static func _norm(v: Variant, depth: int = 0) -> Variant:
        if depth > 8:
                return null
        var t: int = typeof(v)
        if t == TYPE_OBJECT:
                var o: Object = v
                if o == null or not is_instance_valid(o):
                        return null
                var sc: Script = o.get_script()
                var cn: String = String(sc.get_global_name()) if sc != null else ""
                if String(NetCodec.TAGS.get(cn, "")) != "" and "id" in o:
                        return {"$e": NetCodec.TAGS[cn], "i": int(o.get("id"))}
                return null
        if t == TYPE_CALLABLE or t == TYPE_SIGNAL or t == TYPE_RID:
                return null
        if t == TYPE_ARRAY:
                var a: Array = v
                var out: Array = []
                out.resize(a.size())
                for i in a.size():
                        out[i] = _norm(a[i], depth + 1)
                return out
        if t == TYPE_DICTIONARY:
                var d: Dictionary = v
                var out2: Dictionary = {}
                for k: Variant in d:
                        out2[_norm(k, depth + 1) if k is Object else k] = _norm(d[k], depth + 1)
                return out2
        return v


static func _same(a: Variant, b: Variant) -> bool:
        if a is Array or b is Array:
                if not (a is Array and b is Array):
                        return false
                return hash(a) == hash(b)
        if a is Dictionary or b is Dictionary:
                if not (a is Dictionary and b is Dictionary):
                        return false
                return hash(a) == hash(b)
        return a == b


## Deep-strip for the SYS section: same ref convention inside nested containers
## (both values and keys — Country-keyed diplomacy dictionaries must survive).
static func _strip(v: Variant, depth: int) -> Variant:
        if depth > 6:
                return null
        if v is Array:
                var out: Array = []
                out.resize((v as Array).size())
                for i in (v as Array).size():
                        out[i] = _strip(v[i], depth + 1)
                return out
        if v is Dictionary:
                var out2: Dictionary = {}
                for k: Variant in v:
                        var nk: Variant = _norm(k) if k is Object else k
                        out2[nk] = _strip(v[k], depth + 1)
                return out2
        return _norm(v)


## Guest side: resolve a "$e" ref back into an entity.
static func _unstrip(gw: GameWorld, v: Variant) -> Variant:
        if v is Array:
                var out: Array = []
                out.resize((v as Array).size())
                for i in (v as Array).size():
                        out[i] = _unstrip(gw, v[i])
                return out
        if v is Dictionary and (v as Dictionary).has("$e"):
                return gw_entity(gw, String(v["$e"]), int(v["i"]))
        if v is Dictionary:
                var out2: Dictionary = {}
                for k: Variant in v:
                        out2[k] = _unstrip(gw, v[k])
                return out2
        return v


static func kind_list(gw: GameWorld, tag: String) -> Array:
        match tag:
                "U":
                        return gw.army.units
                "D":
                        return gw.mil.drones
                "M":
                        return gw.mil.missiles
                "A":
                        return gw.mil.air.aircraft
                "S":
                        return gw.navy.ships if gw.navy != null else []
                "Y":
                        return gw.cities
                "F":
                        return gw.mil.facilities
                "C":
                        return gw.countries
        return []


## Host: fill the caches with the world AS THE GUESTS BUILT IT FROM THE SEED
## (world gen is seed-deterministic), so the first deltas carry only real
## differences instead of every field of every entity. Called once after the
## host's world is built, before the first turn.
static func host_prime(gw: GameWorld) -> void:
        host_reset()
        for k: int in KIND_TAGS.size():
                var tag: String = KIND_TAGS[k]
                var cur: Dictionary = {}
                for e: Variant in kind_list(gw, tag):
                        var o: Object = e
                        if o == null or not is_instance_valid(o):
                                continue
                        var id: int = int(o.get("id"))
                        if cur.has(id):
                                continue
                        var props: PackedStringArray = _props(o)
                        var skip: Array = SKIP_FIELDS.get(tag, [])
                        var vals: Array = []
                        vals.resize(props.size())
                        for i in props.size():
                                var pn: String = props[i]
                                vals[i] = "" if (pn in skip or pn in SKIP_ANY) else _norm(o.get(pn))
                        cur[id] = vals
                _last_ent[tag] = cur
        _last_map = gw.data.owners.duplicate()
        _last_obj_a.clear()
        for a: String in OBJ_ARRAYS:
                _last_obj_a[a] = _obj_bytes(gw, a)
        _last_obj_size = gw.obj_spr.size()
        for path: String in SYS_FIELDS:
                var sys_obj: Object = _sys_obj(gw, path)
                if sys_obj == null:
                        continue
                for f: String in SYS_FIELDS[path]:
                        if not f in sys_obj:
                                continue
                        _last_sys["%s.%s" % [path, f]] = hash(_strip(sys_obj.get(f), 0))


## v1.3.3: resolve a dotted SYS path ("diplo.ally" -> gw.diplo.ally). Plain paths
## behave exactly as before (gw.<path>).
static func _sys_obj(gw: GameWorld, path: String) -> Object:
        var o: Object = gw
        for seg: String in path.split("."):
                if o == null or not seg in o:
                        return null
                o = o.get(seg) as Object
        return o


## Build one delta frame. fx: the host's FX event buffer (drained by the caller).
static func build_delta(gw: GameWorld, seq: int, speed: int, fx: Array) -> PackedByteArray:
        var sb := StreamPeerBuffer.new()
        sb.big_endian = false
        sb.put_u32(MAGIC)
        sb.put_u32(seq)
        sb.put_double(gw.game_time)
        sb.put_u8(clampi(speed, 1, 9))
        for k: int in KIND_TAGS.size():
                var tag: String = KIND_TAGS[k]
                var list: Array = kind_list(gw, tag)
                var cur: Dictionary = {}
                var props_of: Dictionary = {}
                for e: Variant in list:
                        var o: Object = e
                        if o == null or not is_instance_valid(o):
                                continue
                        var id: int = int(o.get("id"))
                        if cur.has(id):
                                continue  # keep the first (index-addressed kinds may hold null gaps)
                        var props: PackedStringArray = _props(o)
                        var skip: Array = SKIP_FIELDS.get(tag, [])
                        var vals: Array = []
                        vals.resize(props.size())
                        for i in props.size():
                                var pn: String = props[i]
                                var v: Variant = "" if (pn in skip or pn in SKIP_ANY) else _norm(o.get(pn))
                                vals[i] = v
                        cur[id] = vals
                        props_of[id] = props
                var last: Dictionary = _last_ent.get(tag, {})
                # DEL: everything the host no longer has
                var gone: PackedInt32Array = PackedInt32Array()
                for id0: Variant in last:
                        if not cur.has(int(id0)):
                                gone.append(int(id0))
                sb.put_u8(SEC_DEL)
                sb.put_u8(k)
                sb.put_u16(gone.size())
                for g: int in gone:
                        sb.put_u32(g)
                # ENT: changed fields only
                sb.put_u8(SEC_ENT)
                sb.put_u8(k)
                var entries: Array = []  # [id, mask, payload] — mask is never 0 on the wire
                for id2: int in cur:
                        if last.has(id2) and _same(last[id2], cur[id2]):
                                continue  # whole entity identical (fast path: array hash)
                        var props2: PackedStringArray = props_of[id2]
                        var vals2: Array = cur[id2]
                        var prev: Array = last.get(id2, [])
                        var mask: int = 0
                        var payload: Array = []
                        for i in mini(props2.size(), MASK_BITS):
                                var v: Variant = vals2[i]
                                if prev.size() <= i or not _same(prev[i], v):
                                        mask |= (1 << i)
                                        payload.append(v)
                        if mask == 0:
                                # v1.2.4 crash fix: this skip used to run AFTER the u16 count was
                                # already written (facility.gd has 76 script vars; fields 64..75 sit
                                # beyond the u64 mask). A facility changing ONLY a tail field then
                                # produced a counted-but-missing entry — the guest's decoder desynced,
                                # read garbage, and the process died natively (the «2 минуты и кик» /
                                # «реконнект и полный вылет» crashes). Build the list first, write
                                # count == entries written. Tail fields stay unsynced by design
                                # (a u64 mask cannot index them); a keyframe refreshes them.
                                continue
                        entries.append([id2, mask, payload])
                sb.put_u16(entries.size())
                for e3: Variant in entries:
                        sb.put_u32(e3[0])
                        sb.put_u64(e3[1])
                        for pv: Variant in e3[2]:
                                sb.put_var(pv)
                _last_ent[tag] = cur
        # owners chunk-diff (fixed size) + the obj_* block (grows with construction)
        _map_section(sb, SEC_MAP, gw.data.owners, _last_map)
        _obj_section(sb, gw)
        # FX events
        sb.put_u8(SEC_FX)
        sb.put_u16(mini(fx.size(), NetConfig.HS_FX_MAX))
        for i2: int in mini(fx.size(), NetConfig.HS_FX_MAX):
                sb.put_var(fx[i2])
        fx.clear()
        # subsystem state (slow cadence is the caller's choice; changed fields only)
        sb.put_u8(SEC_SYS)
        var sys_rows: Array = []
        for path: String in SYS_FIELDS:
                var sys_obj: Object = _sys_obj(gw, path)
                if sys_obj == null:
                        continue
                for f: String in SYS_FIELDS[path]:
                        if not f in sys_obj:
                                continue
                        var sv: Variant = _strip(sys_obj.get(f), 0)
                        var hh: int = hash(sv)
                        var key: String = "%s.%s" % [path, f]
                        if _last_sys.get(key, -1) == hh:
                                continue
                        _last_sys[key] = hh
                        sys_rows.append([key, sv])
        sb.put_u16(sys_rows.size())
        for row: Variant in sys_rows:
                sb.put_var(row[0])
                sb.put_var(row[1])
        sb.put_u8(SEC_END)
        return sb.data_array


## owners: fixed-size array, one blob (chunk-diff or full).
static func _map_section(sb: StreamPeerBuffer, sec: int, arr: PackedByteArray, last: PackedByteArray) -> void:
        sb.put_u8(sec)
        sb.put_u32(arr.size())
        var chunk: int = NetConfig.HS_MAP_CHUNK
        var bm := PackedByteArray()
        var data := PackedByteArray()
        var full: bool = true
        if arr.size() == last.size() and not arr.is_empty():
                var cd: Dictionary = _chunk_diff(last, arr, chunk)
                if bool(cd.get("ok", false)) and int(cd.get("bytes", arr.size())) < arr.size():
                        bm = cd["bitmap"]
                        data = cd["data"]
                        full = false
        if full:
                data = arr  # bitmap length 0 on the wire = "data is the whole array"
        sb.put_u32(bm.size())
        if not bm.is_empty():
                sb.put_data(bm)
        sb.put_u32(data.size())
        if not data.is_empty():
                sb.put_data(data)
        _last_map = arr.duplicate()


## The world's objects (buildings / trees): seven parallel packed arrays that grow
## together as the economy constructs (and free-ids get reused, so even the prefix
## changes). Modes: 0 = same size, per-array chunk-diffs; 1 = growth (tails for the
## appended objects + prefix diffs for reuse); 2 = full block (put_var each).
const OBJ_I32: Array[String] = ["spr", "x", "y"]
const OBJ_ARRAYS: Array[String] = ["spr", "x", "y", "kind", "state", "hidden", "arch"]


static func _obj_bytes(gw: GameWorld, name: String) -> PackedByteArray:
        match name:
                "spr":
                        return gw.obj_spr.to_byte_array()
                "x":
                        return gw.obj_x.to_byte_array()
                "y":
                        return gw.obj_y.to_byte_array()
                "kind":
                        return gw.obj_kind
                "state":
                        return gw.obj_state
                "hidden":
                        return gw.obj_hidden
                "arch":
                        return gw.obj_arch
        return PackedByteArray()


static func _obj_set_bytes(gw: GameWorld, name: String, b: PackedByteArray) -> void:
        match name:
                "spr":
                        gw.obj_spr = b.to_int32_array()
                "x":
                        gw.obj_x = b.to_int32_array()
                "y":
                        gw.obj_y = b.to_int32_array()
                "kind":
                        gw.obj_kind = b
                "state":
                        gw.obj_state = b
                "hidden":
                        gw.obj_hidden = b
                "arch":
                        gw.obj_arch = b


## [u32 bm_len][bm][u32 data_len][data]; bm_len == 0 means "data is the whole array".
static func _write_blob(sb: StreamPeerBuffer, cd: Dictionary, cur: PackedByteArray) -> void:
        var chunk: int = NetConfig.HS_MAP_CHUNK
        var bm: PackedByteArray = cd.get("bitmap", PackedByteArray())
        var data: PackedByteArray = cd.get("data", PackedByteArray())
        if not bool(cd.get("ok", false)) or int(cd.get("bytes", cur.size())) >= cur.size():
                bm = PackedByteArray()
                data = cur
        sb.put_u32(bm.size())
        if not bm.is_empty():
                sb.put_data(bm)
        sb.put_u32(data.size())
        if not data.is_empty():
                sb.put_data(data)


static func _obj_section(sb: StreamPeerBuffer, gw: GameWorld) -> void:
        sb.put_u8(SEC_OBJ)
        var n: int = gw.obj_spr.size()
        if gw.obj_hidden.size() < n:
                gw.obj_hidden.resize(n)  # the host keeps these lazy; normalize before comparing
        if gw.obj_arch.size() < n:
                gw.obj_arch.resize(n)
        var cur: Dictionary = {}
        var sizes_ok: bool = gw.obj_x.size() == n and gw.obj_y.size() == n and gw.obj_kind.size() == n                 and gw.obj_state.size() == n and gw.obj_hidden.size() == n and gw.obj_arch.size() == n
        for a: String in OBJ_ARRAYS:
                cur[a] = _obj_bytes(gw, a)
                var exp: int = (4 * n) if a in OBJ_I32 else n
                if (cur[a] as PackedByteArray).size() != exp:
                        sizes_ok = false
        if not sizes_ok or _last_obj_size < 0 or n < _last_obj_size or _last_obj_a.is_empty():
                sb.put_u32(n)
                sb.put_u8(2)  # full block
                sb.put_var(gw.obj_spr)
                sb.put_var(gw.obj_x)
                sb.put_var(gw.obj_y)
                sb.put_var(gw.obj_kind)
                sb.put_var(gw.obj_state)
                sb.put_var(gw.obj_hidden)
                sb.put_var(gw.obj_arch)
                _last_obj_a = cur
                _last_obj_size = n
                return
        var chunk: int = NetConfig.HS_MAP_CHUNK
        var grew: bool = n > _last_obj_size
        sb.put_u32(n)
        sb.put_u8(1 if grew else 0)
        var old_n: int = _last_obj_size
        if grew:
                sb.put_u32(old_n)
                for a: String in OBJ_ARRAYS:
                        var nb: PackedByteArray = cur[a]
                        var unit: int = 4 if a in OBJ_I32 else 1
                        var tail: PackedByteArray = nb.slice(unit * old_n)
                        sb.put_u32(tail.size())
                        if not tail.is_empty():
                                sb.put_data(tail)
        for a: String in OBJ_ARRAYS:
                var nb2: PackedByteArray = cur[a]
                var lb2: PackedByteArray = _last_obj_a[a]
                var unit2: int = 4 if a in OBJ_I32 else 1
                if grew:
                        var cut: int = unit2 * old_n
                        var cd: Dictionary = _chunk_diff(lb2.slice(0, cut), nb2.slice(0, cut), chunk)
                        _write_blob(sb, cd, nb2.slice(0, cut))
                else:
                        var cd2: Dictionary = _chunk_diff(lb2, nb2, chunk)
                        _write_blob(sb, cd2, nb2)
        _last_obj_a = cur
        _last_obj_size = n


static func _chunk_diff(old: PackedByteArray, new: PackedByteArray, chunk: int) -> Dictionary:
        if rust_ok:
                var d := DfDelta.new()
                return d.chunk_diff(old, new, chunk)
        var out: Dictionary = {"ok": false}
        if chunk <= 0 or old.size() != new.size():
                return out
        var chunks: int = ceili(float(new.size()) / float(chunk))
        if chunks == 0:
                out["ok"] = true
                out["bitmap"] = PackedByteArray()
                out["data"] = PackedByteArray()
                out["chunks"] = 0
                out["changed"] = 0
                out["bytes"] = 0
                return out
        var bm := PackedByteArray()
        bm.resize((chunks + 7) / 8)
        var data := PackedByteArray()
        var changed: int = 0
        for i: int in chunks:
                var a: int = i * chunk
                var b: int = mini(a + chunk, new.size())
                if old.slice(a, b) != new.slice(a, b):
                        bm[i / 8] = bm[i / 8] | (1 << (i % 8))
                        data.append_array(new.slice(a, b))
                        changed += 1
        out["ok"] = true
        out["bitmap"] = bm
        out["data"] = data
        out["chunks"] = chunks
        out["changed"] = changed
        out["bytes"] = data.size()
        return out


## Guest: read one blob written by _write_blob and apply it onto `cur`.
## Returns the new bytes or an empty array on a mismatch (caller keeps its own).
static func _read_blob(sb: StreamPeerBuffer, cur: PackedByteArray) -> PackedByteArray:
        var bml: int = sb.get_u32()
        var bm: PackedByteArray = _get_bytes(sb, bml)
        var dl: int = sb.get_u32()
        var data: PackedByteArray = _get_bytes(sb, dl)
        if bml == 0 and data.size() == cur.size():
                return data
        if bm.is_empty() or cur.is_empty():
                return PackedByteArray()
        return _chunk_apply(cur, bm, data, NetConfig.HS_MAP_CHUNK, cur.size())


static func _chunk_apply(old: PackedByteArray, bm: PackedByteArray, data: PackedByteArray, chunk: int, total: int) -> PackedByteArray:
        if rust_ok:
                var d := DfDelta.new()
                return d.chunk_apply(old, bm, data, chunk, total)
        var out := PackedByteArray()
        if chunk <= 0 or old.size() != total:
                return out
        out.resize(total)
        for i: int in total:
                out[i] = old[i]
        var chunks: int = ceili(float(total) / float(chunk))
        var cur: int = 0
        for i: int in chunks:
                var byte: int = bm[i / 8] if i / 8 < bm.size() else 0
                if byte & (1 << (i % 8)) == 0:
                        continue
                var a: int = i * chunk
                var b: int = mini(a + chunk, total)
                if cur + (b - a) > data.size():
                        return PackedByteArray()
                for j: int in b - a:
                        out[a + j] = data[cur + j]
                cur += b - a
        return out


# ------------------------------------------------------------------ guest side

## v1.2.2: the guest's world was just built from the seed (net_begin) or rebuilt
## from a keyframe (Save.net_restore) — every object went through add_object and
## is already inside a render chunk. Deltas only need to register ids above this
## mark (see _obj_register).
static func guest_seeded(gw: GameWorld) -> void:
        _obj_reg_n = gw.obj_spr.size() if gw != null and gw.obj_spr != null else 0


## v1.2.2: an OBJ delta replaces the obj_* arrays directly (no add_object), so a
## building the host constructed existed in the guest's data but had no model —
## its id was in no chunk's ids, and it appeared only after the next keyframe
## rebuilt the whole layer. Register every grown tail id into its chunk and mark
## it (the chunk redraws at once); mode 2 (full block) rebuilds the membership.
static func _obj_register(gw: GameWorld, full: bool) -> void:
        if gw == null or gw.objects == null or gw.objects.chunks.is_empty():
                return
        var n: int = gw.obj_spr.size()
        if full or (n < _obj_reg_n):
                _obj_reg_n = 0
                for c: ObjChunk in gw.objects.chunks:
                        c.ids = PackedInt32Array()
                        c.sorted = false
                        c.mark()  # cover/depth caches go stale with the membership
        if _obj_reg_n < 0:
                _obj_reg_n = n  # the seed world was chunk-registered as it was built
                return
        if n <= _obj_reg_n:
                return  # same size: state/sprite changes render on the next chunk redraw
        for id: int in range(_obj_reg_n, n):
                if id >= gw.obj_x.size() or id >= gw.obj_y.size():
                        break
                var sid: int = gw.obj_spr[id]
                var fd: int = gw.spr_fd[sid] if sid >= 0 and sid < gw.spr_fd.size() else 0
                var ck: ObjChunk = gw.objects.chunk_at_cell(gw.obj_x[id], gw.obj_y[id] + fd - 1)
                ck.ids.append(id)
                ck.mark()
        _obj_reg_n = n


## Apply one delta frame. Returns {seq, gt, speed, moved, fx, sys} or null.
static func apply_delta(gw: GameWorld, buf: PackedByteArray) -> Variant:
        if buf.size() < 17:
                return null
        var sb := StreamPeerBuffer.new()
        sb.big_endian = false
        sb.data_array = buf
        if sb.get_u32() != MAGIC:
                return null
        var seq: int = sb.get_u32()
        var gt: float = sb.get_double()
        var spd: int = sb.get_u8()
        var moved: Array = []  # [obj, field, from_value, to_value]
        var fx: Array = []
        var sys: Array = []
        var made_fail: int = 0
        var need_key: bool = false  # v1.2.4: consumed-but-skipped sections self-heal via a keyframe
        while true:
                if not _have(sb, 1):
                        return null  # truncated / desynced frame: reject it whole (never apply half)
                var sec: int = sb.get_u8()
                match sec:
                        SEC_DEL:
                                var k: int = sb.get_u8()
                                var tag: String = KIND_TAGS[k] if k < KIND_TAGS.size() else ""
                                if tag == "":
                                        return null
                                var n: int = sb.get_u16()
                                if not _have(sb, 4 * n):
                                        return null
                                for i: int in n:
                                        _remove_entity(gw, tag, sb.get_u32())
                        SEC_ENT:
                                var k2: int = sb.get_u8()
                                var tag2: String = KIND_TAGS[k2] if k2 < KIND_TAGS.size() else ""
                                if tag2 == "":
                                        return null
                                var n2: int = sb.get_u16()
                                for i2: int in n2:
                                        if not _have(sb, 12):
                                                return null  # u32 id + u64 mask must be on the wire
                                        var id: int = sb.get_u32()
                                        var mask: int = sb.get_u64()
                                        var e: Object = gw_entity(gw, tag2, id)
                                        if e == null:
                                                e = _make_entity(gw, tag2, id)
                                        if e == null:
                                                made_fail += 1  # a kind we cannot create: the guest asks for a keyframe
                                        var props: PackedStringArray = _props(e) if e != null else PackedStringArray()
                                        # v1.2.4 crash fix: ONE var is consumed per set bit, unconditionally —
                                        # the encoder writes exactly that. The old loop read only bits below
                                        # the guest's own props count, so a field the guest's script does not
                                        # have (or an entity we could not build) left payload bytes unread and
                                        # desynced the stream — the same crash family as the mask==0 skip.
                                        for b: int in MASK_BITS:
                                                if mask & (1 << b) == 0:
                                                        continue
                                                var v: Variant = sb.get_var()
                                                if e == null or b >= props.size():
                                                        continue  # keep the stream aligned; the keyframe heals the value
                                                var fname: String = props[b]
                                                if fname in SKIP_FIELDS.get(tag2, []):
                                                    continue  # never touch live node handles / save-special fields
                                                if fname == POS_FIELD.get(tag2, "") and fname in e:
                                                        var from_v: Variant = e.get(fname)
                                                        if (from_v is Vector2 and v is Vector2) or (from_v is float and v is float):
                                                                moved.append([e, fname, from_v, v])
                                                                _set_field(e, fname, from_v)  # the interp window starts from the visible position
                                                        else:
                                                                _set_field(e, fname, v)
                                                elif fname in e:
                                                        _set_field(e, fname, _unstrip(gw, v))
                        SEC_MAP:
                                if not _have(sb, 8):
                                        return null
                                var total: int = sb.get_u32()
                                var bml: int = sb.get_u32()
                                if bml > sb.get_available_bytes():
                                        return null  # v1.2.4: never take a wire length on faith
                                var bm: PackedByteArray = _get_bytes(sb, bml)
                                var dl: int = sb.get_u32()
                                if dl > sb.get_available_bytes():
                                        return null
                                var data: PackedByteArray = _get_bytes(sb, dl)
                                if bm.is_empty() and data.size() == total:
                                        gw.data.owners = data
                                else:
                                        var arr: PackedByteArray = _chunk_apply(gw.data.owners, bm, data, NetConfig.HS_MAP_CHUNK, total)
                                        if not arr.is_empty():
                                                gw.data.owners = arr
                                gw.data.owners_dirty = true
                        SEC_OBJ:
                                if not _have(sb, 5):
                                        return null
                                var total2: int = sb.get_u32()
                                var mode: int = sb.get_u8()
                                match mode:
                                        2:  # full block
                                                var s2: Variant = sb.get_var()
                                                var x2: Variant = sb.get_var()
                                                var y2: Variant = sb.get_var()
                                                var k2: Variant = sb.get_var()
                                                var st2: Variant = sb.get_var()
                                                var hd2: Variant = sb.get_var()
                                                var ar2: Variant = sb.get_var()
                                                if s2 is PackedInt32Array and x2 is PackedInt32Array and y2 is PackedInt32Array \
                                                                and k2 is PackedByteArray and st2 is PackedByteArray and hd2 is PackedByteArray and ar2 is PackedByteArray:
                                                        gw.obj_spr = s2
                                                        gw.obj_x = x2
                                                        gw.obj_y = y2
                                                        gw.obj_kind = k2
                                                        gw.obj_state = st2
                                                        gw.obj_hidden = hd2 if (hd2 as PackedByteArray).size() == (st2 as PackedByteArray).size() else gw.obj_hidden
                                                        gw.obj_arch = ar2 if (ar2 as PackedByteArray).size() == (st2 as PackedByteArray).size() else gw.obj_arch
                                                        gw.data.owners_dirty = true
                                        0:  # same size: per-array chunk-diffs
                                                var bad: bool = false
                                                for a: String in OBJ_ARRAYS:
                                                        var cur: PackedByteArray = _obj_bytes(gw, a)
                                                        var nw: PackedByteArray = _read_blob(sb, cur)
                                                        if nw.is_empty():
                                                                bad = true
                                                        else:
                                                                _obj_set_bytes(gw, a, nw)
                                                if not bad:
                                                        gw.data.owners_dirty = true
                                                else:
                                                        need_key = true  # v1.2.4: stale baseline — a keyframe heals it
                                        1:  # growth: [old_n][tails x7][prefix blobs x7]
                                                var old_n: int = sb.get_u32()
                                                var tails: Dictionary = {}
                                                var ok_t: bool = true
                                                for a2: String in OBJ_ARRAYS:
                                                        if not _have(sb, 4):
                                                                return null
                                                        var tl: int = sb.get_u32()
                                                        if tl > sb.get_available_bytes():
                                                                return null
                                                        var t: PackedByteArray = _get_bytes(sb, tl)
                                                        var unit: int = 4 if a2 in OBJ_I32 else 1
                                                        if t.size() != unit * (total2 - old_n):
                                                                ok_t = false
                                                        tails[a2] = t
                                                # v1.2.4 crash fix: the prefix blobs are ALWAYS on the wire (the
                                                # host writes them unconditionally). The old decoder skipped
                                                # consuming them when old_n did not match the guest's array
                                                # size — right after a rejoin/restore the next growth delta
                                                # then desynced the stream and the process died. Consume first,
                                                # decide after; any mismatch heals via a keyframe request.
                                                var blobs: Array = []
                                                for a3: String in OBJ_ARRAYS:
                                                        blobs.append(_read_blob(sb, _obj_bytes(gw, a3)))
                                                if old_n == gw.obj_spr.size() and ok_t:
                                                        var bad2: bool = false
                                                        for bi: int in blobs.size():
                                                                if (blobs[bi] as PackedByteArray).is_empty():
                                                                        bad2 = true
                                                                        break
                                                        if not bad2:
                                                                for bi2: int in blobs.size():
                                                                        _obj_set_bytes(gw, OBJ_ARRAYS[bi2], blobs[bi2])
                                                                for a4: String in OBJ_ARRAYS:
                                                                        var t4: PackedByteArray = tails[a4]
                                                                        if a4 in OBJ_I32:
                                                                                var ints: PackedInt32Array = t4.to_int32_array()
                                                                                var arr4: PackedInt32Array = _obj_arr_i32(gw, a4)
                                                                                arr4.resize(total2)
                                                                                for i4: int in ints.size():
                                                                                        arr4[old_n + i4] = ints[i4]
                                                                        else:
                                                                                var arr5: PackedByteArray = _obj_arr_i8(gw, a4)
                                                                                arr5.resize(total2)
                                                                                for i5: int in t4.size():
                                                                                        arr5[old_n + i5] = t4[i5]
                                                                gw.data.owners_dirty = true
                                                        else:
                                                                need_key = true  # v1.2.4: baseline mismatch — heal via keyframe
                                                else:
                                                        need_key = true  # v1.2.4: missed growth deltas (restore/rejoin window) — heal via keyframe
                                _obj_register(gw, mode == 2)  # v1.2.2: new ids have no model until they join a render chunk
                        SEC_FX:
                                if not _have(sb, 2):
                                        return null
                                var nf: int = sb.get_u16()
                                for i3: int in nf:
                                        var ev: Variant = sb.get_var()
                                        if ev is Dictionary:
                                                fx.append(ev)
                        SEC_SYS:
                                if not _have(sb, 2):
                                        return null
                                var ns: int = sb.get_u16()
                                for i4: int in ns:
                                        var key: Variant = sb.get_var()
                                        var val: Variant = sb.get_var()
                                        if key is String:
                                                sys.append([key, val])
                        SEC_END:
                                break
                        _:
                                return null  # unknown section: never apply half a frame
        return {"seq": seq, "gt": gt, "speed": spd, "moved": moved, "fx": fx, "sys": sys, "made_fail": made_fail, "need_key": need_key}


static func apply_sys(gw: GameWorld, sys: Array) -> void:
        for row: Variant in sys:
                var parts: PackedStringArray = String(row[0]).split(".")
                if parts.size() < 2:
                        continue
                var obj: Object = _sys_obj(gw, ".".join(parts.slice(0, parts.size() - 1)))
                var field: String = parts[parts.size() - 1]
                if obj != null and field in obj:
                        _set_field(obj, field, _unstrip(gw, row[1]))


## StreamPeer.get_data's return shape differs across Godot builds
## ([err, bytes] vs bytes); accept both.
## v1.2.4: does the buffer still hold at least n unread bytes? Every structural
## read in apply_delta goes through this — a truncated/desynced frame must fail
## cleanly (return null → keyframe request) instead of parsing garbage.
static func _have(sb: StreamPeerBuffer, n: int) -> bool:
        return sb.get_available_bytes() >= n


static func _get_bytes(sb: StreamPeerBuffer, n: int) -> PackedByteArray:
        if n <= 0:
                return PackedByteArray()
        if n > sb.get_available_bytes():
                # v1.2.4 crash fix: a desynced stream can hand us a garbage u32 length
                # (up to 4 GiB). StreamPeerBuffer.get_data would resize to that count
                # and abort the process natively — the hard «closed with no trace»
                # crashes. Callers treat the empty result as a mismatch.
                return PackedByteArray()
        var rd: Variant = sb.get_data(n)
        if rd is Array:
                return rd[1] if rd.size() > 1 else PackedByteArray()
        return rd if rd is PackedByteArray else PackedByteArray()


static func _obj_arr_i32(gw: GameWorld, name: String) -> PackedInt32Array:
        match name:
                "spr":
                        return gw.obj_spr
                "x":
                        return gw.obj_x
                "y":
                        return gw.obj_y
        return PackedInt32Array()


static func _obj_arr_i8(gw: GameWorld, name: String) -> PackedByteArray:
        match name:
                "kind":
                        return gw.obj_kind
                "state":
                        return gw.obj_state
                "hidden":
                        return gw.obj_hidden
                "arch":
                        return gw.obj_arch
        return PackedByteArray()


static func gw_entity(gw: GameWorld, tag: String, id: int) -> Object:
        match tag:
                "C":
                        return gw.country_by_id(id)
                "Y":
                        return gw.cities[id] if id >= 0 and id < gw.cities.size() else null
                "F":
                        var fl: Array = gw.mil.facilities
                        return fl[id] if id >= 0 and id < fl.size() else null
                "U":
                        for u: Object in gw.army.units:
                                if u != null and int(u.get("id")) == id:
                                        return u
                "D":
                        for d: Object in gw.mil.drones:
                                if d != null and int(d.get("id")) == id:
                                        return d
                "M":
                        for m: Object in gw.mil.missiles:
                                if m != null and int(m.get("id")) == id:
                                        return m
                "A":
                        for a: Object in gw.mil.air.aircraft:
                                if a != null and int(a.get("id")) == id:
                                        return a
                "S":
                        if gw.navy != null:
                                return gw.navy.ship(id)
        return null


static func _make_entity(gw: GameWorld, tag: String, id: int) -> Object:
        var sc: Script = load(ENT_SCRIPT.get(tag, "")) as Script
        if sc == null:
                return null
        var o: Object = sc.new()
        if not "id" in o:
                return null
        o.set("id", id)
        var list: Array = kind_list(gw, tag)
        match tag:
                "Y", "F", "C":
                        var idx: int = id if tag != "C" else id - 1
                        while list.size() <= idx:
                                list.append(null)
                        list[idx] = o
                _:
                        list.append(o)
        return o


static func _remove_entity(gw: GameWorld, tag: String, id: int) -> void:
        match tag:
                "U", "D", "M", "A":
                        var list: Array = kind_list(gw, tag)
                        for i: int in range(list.size() - 1, -1, -1):
                                var e: Variant = list[i]
                                if e != null and is_instance_valid(e) and int((e as Object).get("id")) == id:
                                        list.remove_at(i)
                "S":
                        if gw.navy != null:
                                gw.navy.ships.erase(gw.navy.ship(id))
                "Y", "F", "C":
                        var list2: Array = kind_list(gw, tag)
                        var idx: int = id if tag != "C" else id - 1
                        if idx >= 0 and idx < list2.size():
                                list2[idx] = null  # keep the id == index invariant (gw_map, ArmyGroups.fac)


## Typed-safe field assignment (mirrors Save._assign).
static func _set_field(o: Object, n: String, v: Variant) -> void:
        var cur: Variant = o.get(n)
        var tc: int = typeof(cur)
        if tc == TYPE_ARRAY and typeof(v) == TYPE_ARRAY and (cur as Array).is_typed():
                var ca: Array = cur
                var typed := Array([], ca.get_typed_builtin(), ca.get_typed_class_name(), ca.get_typed_script())
                typed.assign(v)
                o.set(n, typed)
                return
        if tc == TYPE_DICTIONARY and typeof(v) == TYPE_DICTIONARY and (cur as Dictionary).is_typed():
                var cd: Dictionary = cur
                var td := Dictionary({}, cd.get_typed_key_builtin(), cd.get_typed_key_class_name(), cd.get_typed_key_script(),
                        cd.get_typed_value_builtin(), cd.get_typed_value_class_name(), cd.get_typed_value_script())
                td.assign(v)
                o.set(n, td)
                return
        if tc == TYPE_OBJECT and cur != null and not (cur is Country or cur is City or cur is Facility
                        or cur is Unit or cur is Drone or cur is Missile or cur is Aircraft or cur is Ship):
                return  # never overwrite a live non-entity ref (nodes, systems) with null data
        o.set(n, v)
