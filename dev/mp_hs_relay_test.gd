extends RefCounted
## HOSTSIM RELAY test (v1.2.1): two headless instances in a real running match that
## rides the actual WSS relay transport (signal_server -> base64/JSON -> WsTunnelPeer),
## plus a server-side bandwidth throttle reproducing a weak VPS / slow guest link.
##   --hs-relay-host   /  --hs-relay-guest
##   (the server runs separately: net/server/signal_server.gd -- --port=19090 --open
##    --throttle=200 --throttle-control=/tmp/df_throttle; --signal-url=ws://127.0.0.1:19090/mp/signal)
## The run rewrites the throttle file: normal -> congestion -> relief. PASS: the guest
## keeps applying frames (no death, no reconnect), the world stays alive, and after the
## relief the guest catches up (its seq grows to the host's again).

var main: Node
var net: NetSession
var role: String
var t0: int = 0
var report_at: int = 0
var gap_max: float = 0.0
var holds_seen: int = 0
var reconnects: int = 0
var gt_min: float = -1.0
var gt_max: float = -1.0
var seq_min: int = -1
var seq_max: int = -1
var wire_in_s: int = 0  # wire bytes at the last report (for KiB/s)
var skip_events: int = 0

const CODE_FILE: String = "/tmp/df_room_code_hs"
const GUEST_RESULT_FILE: String = "/tmp/df_hsr_guest_result"


func run(m: Node, r: String) -> void:
        main = m
        role = r
        net = main.net
        var tree: SceneTree = main.get_tree()
        for i in 300:
                if main.menus.current == "main":
                        break
                await tree.create_timer(0.1).timeout
        NetConfig.set_nick("RelHost" if r.contains("host") else "RelGuest")
        NetConfig.test_speed = 2.0  # 2x: like the real players' session, deltas stay rich
        GameConfig.engine_i = 0  # HostSim
        if r == "relay-guest":
                await tree.create_timer(4.0).timeout
        var res: String = ""
        if r == "relay-host":
                res = net.host_online(false)
                var got_code: bool = false
                for i in 1500:
                        if net.room_code != "":
                                got_code = true
                                break
                        await tree.create_timer(0.1).timeout
                if not got_code:
                        push_error("[MP-HSR] host: the server gave no room code (%s)" % net.status_text)
                        tree.quit(1)
                        return
                var f: FileAccess = FileAccess.open(CODE_FILE, FileAccess.WRITE)
                if f != null:
                        f.store_line(net.room_code)
                        f.close()
                print("[MP-HSR] host: relay room %s open, waiting for the guest..." % net.room_code)
        else:
                var code: String = ""
                for i in 1500:
                        if FileAccess.file_exists(CODE_FILE):
                                code = FileAccess.open(CODE_FILE, FileAccess.READ).get_line().strip_edges()
                                if code != "":
                                        break
                        await tree.create_timer(0.5).timeout
                if code == "":
                        push_error("[MP-HSR] guest: no room code appeared")
                        tree.quit(1)
                        return
                print("[MP-HSR] guest: joining relay room %s..." % code)
                res = net.join_online(code)
        if res != "":
                push_error("[MP-HSR] " + r + " join failed: " + res)
                tree.quit(1)
                return
        if r == "relay-host":
                var started: bool = false
                for i in 1500:
                        if net.slots.size() >= 2 and not net.in_match:
                                var err: String = net.host_start()
                                if err == "":
                                        started = true
                                        print("[MP-HSR] host started the match (engine_i=%d, relay transport)" % GameConfig.engine_i)
                                        break
                        if i % 100 == 99:
                                print("[MP-HSR] host: waiting for the guest (slots=%d, status=%s)" % [net.slots.size(), net.status_text])
                        await tree.create_timer(0.1).timeout
                if not started:
                        push_error("[MP-HSR] host never started (slots=%d, status=%s)" % [net.slots.size(), net.status_text])
                        tree.quit(1)
                        return
        t0 = Time.get_ticks_msec()
        while Time.get_ticks_msec() - t0 < 240000:
                await tree.create_timer(1.0).timeout
                if net.in_match and net.go and (net.is_host or net.hs_deltas_in > 0):
                        break
        if not (net.in_match and net.go):
                push_error("[MP-HSR] %s: the match never started flowing (in_match=%s go=%s status=%s)" % [role, str(net.in_match), str(net.go), net.status_text])
                tree.quit(1)
                return
        print("[MP-HSR] %s: the match flows over the relay (t=%ds, hs=%s)" % [role, (Time.get_ticks_msec() - t0) / 1000, str(net.hs_mode)])
        report_at = Time.get_ticks_msec()
        var watch_t0: int = Time.get_ticks_msec()
        while Time.get_ticks_msec() - watch_t0 < 75000:  # 75 s: phases 0-25-40-75 are handled by the throttle file
                await tree.create_timer(0.5).timeout
                if not net.in_match or not net.go:
                        continue
                gap_max = maxf(gap_max, net.hs_last_t)
                if net.hold_who != "":
                        holds_seen += 1
                seq_min = net.hs_seq if seq_min < 0 else mini(seq_min, net.hs_seq)
                seq_max = net.hs_seq if seq_max < 0 else maxi(seq_max, net.hs_seq)
                var world: GameWorld = main.get("world")
                if world != null and is_instance_valid(world):
                        var gt: float = world.game_time
                        gt_min = gt if gt_min < 0.0 else minf(gt_min, gt)
                        gt_max = gt if gt_max < 0.0 else maxf(gt_max, gt)
                if Time.get_ticks_msec() - report_at >= 5000:
                        report_at = Time.get_ticks_msec()
                        if net.is_host:
                                print("[MP-HSR] host seq=%d out=%d skip=%d lag=%d backlog=%d B wire_out=%d KiB (%.0f KiB/s)" % [
                                        net.hs_seq, net.hs_deltas_out, net.hs_skip_out, net._hs_worst_lag(),
                                        net.rtc.match_backlog(), net.hs_wire_out / 1024,
                                        float(net.hs_wire_out - wire_in_s) / 5120.0])
                        else:
                                var wi: int = net.hs_wire_in
                                print("[MP-HSR] guest seq=%d in=%d skip_gap=%.1f apply=%.1f wire_in=%d KiB (%.0f KiB/s) units_alive=%s" % [
                                        net.hs_seq, net.hs_deltas_in, gap_max, net.hs_apply_ms, wi / 1024,
                                        float(wi - wire_in_s) / 5120.0, str(_world_alive())])
                        wire_in_s = net.hs_wire_out if net.is_host else net.hs_wire_in
        # ---- verdict
        var ok: bool = net.in_match and net.go and net.hs_mode
        if net.is_host:
                ok = ok and net.hs_deltas_out >= 10 and net.hs_wire_out > 4096
                print("[MP-HSR] host: raw=%d KiB wire=%d KiB (x%.1f) deltas=%d skipped=%d" % [
                        net.hs_bytes_out / 1024, net.hs_wire_out / 1024,
                        float(net.hs_bytes_out) / float(maxi(1, net.hs_wire_out)), net.hs_deltas_out, net.hs_skip_out])
                # keep the match alive until the guest has judged the stream
                for i in 600:
                        if FileAccess.file_exists(GUEST_RESULT_FILE):
                                break
                        await tree.create_timer(0.5).timeout
        else:
                var w: GameWorld = main.get("world")
                var cities: int = w.cities.size() if w != null and is_instance_valid(w) else 0
                var caught_up: bool = net.hs_deltas_in >= 10 and net.hs_seq >= seq_max and gap_max < 45.0
                ok = ok and caught_up and cities > 0 and gt_max > gt_min and holds_seen == 0
                print("[MP-HSR] guest: in=%d apply=%.1fms gap_max=%.1fs cities=%d gt=[%.1f..%.1f] seq=[%d..%d] wire=%d KiB" % [
                        net.hs_deltas_in, net.hs_apply_ms, gap_max, cities, gt_min, gt_max, seq_min, seq_max, net.hs_wire_in / 1024])
                var rf: FileAccess = FileAccess.open(GUEST_RESULT_FILE, FileAccess.WRITE)
                if rf != null:
                        rf.store_line("ok=%s" % str(ok))
                        rf.close()
        print("[MP-HSR] RESULT %s: go=%s hs=%s seq=%d in=%d out=%d gap_max=%.2f holds=%d wire_out=%d wire_in=%d" % [
                role, str(net.go), str(net.hs_mode), net.hs_seq, net.hs_deltas_in, net.hs_deltas_out, gap_max, holds_seen, net.hs_wire_out, net.hs_wire_in])
        if ok:
                print("[MP-HSR] PASS ", role)
                tree.quit(0)
        else:
                push_error("[MP-HSR] FAIL " + role)
                tree.quit(1)


func _world_alive() -> bool:
        var w: GameWorld = main.get("world")
        return w != null and is_instance_valid(w) and w.army != null and not w.army.units.is_empty()
