## Reborn: тест tick_groups — однопроходная группировка юнитов в Rust.
extends SceneTree


func _initialize() -> void:
	_run()


func _run() -> void:
	await process_frame
	if not ClassDB.class_exists("DFArmy"):
		print("[tg] NO DFArmy")
		quit(1)
		return
	var core: Variant = ClassDB.instantiate("DFArmy")
	# 6 юнитов: 3 у дома 5 (2 op_on, 1 в окопе), 1 у дома 5 с reinf, 1 у дома 7, 1 мёртвый у дома 5
	var uh := PackedInt32Array([5, 5, 5, 5, 7, 5])
	var ua := PackedByteArray([1, 1, 1, 1, 1, 0])
	var ug := PackedByteArray([1, 1, 1, 1, 1, 1])
	var uo := PackedByteArray([1, 1, 0, 0, 0, 0])
	var upp := PackedByteArray([0, 0, 1, 0, 0, 0])
	var ur := PackedByteArray([0, 0, 0, 2, 0, 0])
	var uhp := PackedFloat32Array([100.0, 50.0, 30.0, 40.0, 10.0, 99.0])
	var upx := PackedFloat32Array([1.0, 2.0, 3.0, 4.0, 8.0, 5.0])
	var upy := PackedFloat32Array([6.0, 7.0, 8.0, 9.0, 10.0, 11.0])
	var res: Dictionary = core.call("tick_groups", uh, ua, ug, uo, upp, ur, uhp, upx, upy)
	var mo: Dictionary = res.get("members_op_on", {})
	var mf: Dictionary = res.get("members_free", {})
	var ma: Dictionary = res.get("members_all", {})
	var php: Dictionary = res.get("post_hp", {})
	var cx: Dictionary = res.get("cen_x", {})
	print("[tg] op_on[5]=", mo.get(5, []), " expect [0,1]")
	print("[tg] free[5]=", mf.get(5, []), " expect [3] (пост у 2, reinf у 3)")
	print("[tg] all[5]=", ma.get(5, []), " expect [0,1,2,3]")
	print("[tg] all[7]=", ma.get(7, []), " expect [4]")
	print("[tg] post_hp[5]=", php.get(5, 0.0), " expect 30.0")
	print("[tg] cen_x[5]=", cx.get(5, 0.0), " expect 3.0 (1+2)")
	print("[tg] op_on has 7? ", mo.has(7), " expect false")
	core.free()
	print("[tg] ALL OK")
	quit(0)
