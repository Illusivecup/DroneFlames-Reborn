extends SceneTree
## Quick parse/load check for the v1.2.1 net changes (run: godot --headless -s dev/check_net_load.gd)

func _initialize() -> void:
	var ok: bool = true
	for p: String in ["res://net/net_config.gd", "res://net/rtc_link.gd", "res://net/net_session.gd",
			"res://net/server/signal_server.gd", "res://net/hs_codec.gd", "res://net/ws_tunnel_peer.gd"]:
		var s: Script = load(p)
		if s == null or not s.can_instantiate() and p != "res://net/net_config.gd":
			print("[CHECK] FAIL ", p)
			ok = false
		else:
			print("[CHECK] OK   ", p)
	# zstd round-trip sanity (the HSC1 helpers live in NetSession)
	var raw := PackedByteArray()
	for i: int in 4096:
		raw.append_array(PackedByteArray([1, 2, 3, 4, 0, 0, 0, 7]))
	var wire: PackedByteArray = NetSession._z_pack(raw)
	var back: PackedByteArray = NetSession._z_unpack(wire)
	print("[CHECK] zstd: %d B -> %d B -> %d B, roundtrip=%s" % [raw.size(), wire.size(), back.size(), str(back == raw)])
	ok = ok and back == raw and wire.size() < raw.size() / 2
	print("[CHECK] RESULT: ", "PASS" if ok else "FAIL")
	quit(0 if ok else 1)
