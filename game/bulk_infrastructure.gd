extends RefCounted
## A local-only convenience over the existing Economy.upgrade rules.
##
## v1.3.0: жадное планирование массовых улучшений вынесено в Rust-ядро dfarmy
## (DFArmy.bulk_plan — детерминировано, покрыто тестами rust/dfarmy/tests/bulk.rs).
## Без натива работает GDScript-эталон с тем же алгоритмом (паритет проверен).

static var _core: Object = null
static var _core_tried: bool = false


static func _rust() -> Object:
	if not _core_tried:
		_core_tried = true
		if ClassDB.class_exists("DFArmy"):
			_core = ClassDB.instantiate("DFArmy")
	return _core


static func plan(econ: Variant, facilities: Array, player: Country) -> Dictionary:
	var selected: Array = []
	var total: Dictionary = {}
	var eligible: int = 0
	if econ == null or player == null:
		return {"items": selected, "cost": total, "eligible": eligible}
	# 1. Правила остаются в GDScript: кто может улучшаться и почём.
	var keys: Array = []
	var cost_dicts: Array = []
	var facs: Array = []
	for f: Facility in facilities:
		if f == null or f.country_id != player.id or not econ.can_upgrade(f):
			continue
		eligible += 1
		var cost: Dictionary = econ.upgrade_cost(f)
		if cost.is_empty():
			continue
		cost_dicts.append(cost)
		facs.append(f)
		for key: String in cost:
			if not keys.has(key):
				keys.append(key)
	var k: int = keys.size()
	var n: int = cost_dicts.size()
	# 2. Жадный выбор по бюджетам — Rust-ядро, иначе GDScript-эталон.
	if n > 0:
		var core: Object = _rust()
		var budgets: = PackedInt64Array()
		budgets.resize(k)
		for t: int in k:
			budgets[t] = int(player.get(keys[t]))
		var flat: = PackedInt64Array()
		var off: = PackedInt32Array()
		off.append(0)
		for cost: Dictionary in cost_dicts:
			for t: int in k:
				flat.append(int(cost.get(keys[t], 0)))
			off.append(flat.size())
		if core != null:
			var res: PackedInt64Array = core.call("bulk_plan", flat, off, budgets)
			for i: int in n:
				if int(res[i]) == 1:
					selected.append({"facility": facs[i], "cost": cost_dicts[i]})
			for t: int in k:
				if int(res[n + t]) != 0:
					total[keys[t]] = int(res[n + t])
			return {"items": selected, "cost": total, "eligible": eligible}
		# GDScript-эталон (без нативного ядра) — тот же жадный проход.
		var remaining: Dictionary = {}
		for i: int in n:
			var cost: Dictionary = cost_dicts[i]
			var affordable: bool = true
			for key: String in cost:
				if not remaining.has(key):
					remaining[key] = int(player.get(key))
				if int(cost[key]) < 0 or int(remaining[key]) < int(cost[key]):
					affordable = false
			if not affordable:
				continue
			for key: String in cost:
				remaining[key] = int(remaining[key]) - int(cost[key])
				total[key] = int(total.get(key, 0)) + int(cost[key])
			selected.append({"facility": facs[i], "cost": cost})
	return {"items": selected, "cost": total, "eligible": eligible}


static func apply(econ: Variant, facilities: Array, player: Country, preview: Dictionary) -> int:
	if econ == null or player == null:
		return 0
	var done: int = 0
	for item: Dictionary in preview.get("items", []):
		var f: Facility = item.get("facility") as Facility
		var cost: Dictionary = item.get("cost", {})
		if f == null or not facilities.has(f) or f.country_id != player.id or not econ.can_upgrade(f):
			continue
		if cost.is_empty() or econ.upgrade_cost(f) != cost or not player.has_res(cost):
			continue
		if String(econ.upgrade(f, player)) == "":
			done += 1
	return done
