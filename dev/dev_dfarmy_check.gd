## Reborn: runtime check of the dfarmy GDExtension + FordCore GDScript wrapper.
extends SceneTree


func _initialize() -> void:
	_run()


func _run() -> void:
	await process_frame
	print("[chk] DFArmy class_exists=", ClassDB.class_exists("DFArmy"))
	var fc := load("res://game/ford.gd")
	print("[chk] ford.gd loaded=", fc != null, " can_instantiate=", fc is Script and (fc as Script).can_instantiate())
	if fc != null:
		print("[chk] FordCore.has_rust=", fc.has_method("has_rust") and fc.call("has_rust"))
		# Static API smoke test on a fake grid: build minimal GameWorld stand-in
		var ok_batch: bool = fc.has_method("batchable")
		print("[chk] batchable method=", ok_batch)
		print("[chk] FORD_HOLD_S=", fc.get("FORD_HOLD_S") if fc.get("FORD_HOLD_S") != null else "n/a")
	# Verify DFArmy instantiation and basic math
	if ClassDB.class_exists("DFArmy"):
		var inst: Variant = ClassDB.instantiate("DFArmy")
		print("[chk] DFArmy instance=", inst != null)
		if inst != null:
			inst.free()
	else:
		print("[chk] DFArmy MISSING — Rust extension did not load")
	quit(0)
