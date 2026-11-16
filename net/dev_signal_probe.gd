## Reborn: e2e probe of the signal server reachable from the real game code path.
## Run: godot --headless --path . --script res://net/dev_signal_probe.gd
## Env: PROBE_URL=wss://... to override the target.
extends SceneTree

const ROOTS := "res://net/tls/backend_roots.crt"
const HOST_MSG := {
	"t": "host",
	"v": "Reborn v1.1.0/7",
	"pub": false,
	"code": "",
	"name": "RebornProbe",
	"auth_user": "",
	"auth_token": "",
}
const WAIT_OPEN_MS := 15000
const WAIT_MSG_MS := 9000

var _ws: WebSocketPeer = null
var _t0: int = 0
var _phase: int = 0  # 0=connecting, 1=open+waiting msgs
var _sent: bool = false
var _got: Array = []


func _initialize() -> void:
	var url: String = OS.get_environment("PROBE_URL")
	if url == "":
		url = "wss://drone-flames.snaipix.com/mp/signal"
	print("[probe] target=", url)
	var tls: TLSOptions = null
	if url.begins_with("wss://"):
		if url.contains("snaipix.com"):
			var roots: X509Certificate = X509Certificate.new()
			var e: Error = roots.load(ROOTS)
			print("[probe] roots load=", error_string(e))
			tls = TLSOptions.client(roots)
		else:
			tls = TLSOptions.client_unsafe()
	_ws = WebSocketPeer.new()
	_ws.inbound_buffer_size = 1048576
	_ws.outbound_buffer_size = 1048576
	var err: Error = _ws.connect_to_url(url, tls)
	print("[probe] connect_to_url => ", error_string(err), " (", err, ")")
	if err != OK:
		quit(2)
		return
	_t0 = Time.get_ticks_msec()


func _process(_delta: float) -> bool:
	if _ws == null:
		return true
	_ws.poll()
	var st: int = _ws.get_ready_state()
	var now: int = Time.get_ticks_msec()
	if _phase == 0:
		if st == WebSocketPeer.STATE_OPEN:
			print("[probe] WSS OPEN in ", now - _t0, " ms")
			_phase = 1
			_t0 = now
		elif st == WebSocketPeer.STATE_CLOSED:
			print("[probe] CLOSED before open: code=", _ws.get_close_code(), " reason=", _ws.get_close_reason())
			quit(3)
			return true
		elif now - _t0 > WAIT_OPEN_MS:
			print("[probe] TIMEOUT connecting (", WAIT_OPEN_MS, " ms)")
			quit(4)
			return true
		return false
	# phase 1: send host message once, then collect responses
	if not _sent:
		_ws.send_text(JSON.stringify(HOST_MSG))
		_sent = true
		print("[probe] host message sent")
	while _ws.get_available_packet_count() > 0:
		var pkt: Variant = _ws.get_packet()
		if pkt is PackedByteArray:
			var s: String = (pkt as PackedByteArray).get_string_from_utf8()
			if s.length() > 400:
				s = s.substr(0, 400) + "..."
			_got.append(s)
			print("[probe] <- ", s)
	if st == WebSocketPeer.STATE_CLOSED:
		print("[probe] CLOSED after ", Time.get_ticks_msec() - _t0, " ms; msgs=", _got.size())
		quit(0 if _got.size() > 0 else 5)
		return true
	if now - _t0 > WAIT_MSG_MS:
		print("[probe] done waiting; total msgs=", _got.size())
		quit(0 if _got.size() > 0 else 5)
		return true
	return false
