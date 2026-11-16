extends RefCounted
## HOSTSIM test (v1.2, docs/HOSTSIM.md): two headless instances in a real running match
## over LAN (ENet, loopback) with the host-authoritative engine.
##   --hs-host / --hs-guest
## PASS: hs_mode is on everywhere, host streams deltas, the guest applies them
## (alive world, no gaps, no lockstep holds), the lockstep machinery stays dormant.
## Bandwidth / apply-cost are printed as diagnostics.

var main: Node
var net: NetSession
var role: String
var t0: int = 0
var report_at: int = 0
var gap_max: float = 0.0
var holds_seen: int = 0
var gt_min: float = -1.0
var gt_max: float = -1.0
var fx_seen: int = 0

const GUEST_RESULT_FILE: String = "/tmp/df_hs_guest_result"

func run(m: Node, r: String) -> void:
        main = m
        role = r
        net = main.net
        var tree: SceneTree = main.get_tree()
        for i in 300:
                if main.menus.current == "main":
                        break
                await tree.create_timer(0.1).timeout
        NetConfig.set_nick("HsHost" if r.contains("host") else "HsGuest")
        NetConfig.test_speed = 8.0  # 8x: more deltas and combat in the same wall time
        GameConfig.engine_i = 0  # HostSim explicitly (the default, but the test pins it)
        if r == "lan-guest":
                await tree.create_timer(4.0).timeout
        var res: String = ""
        if r == "lan-host":
                res = net.host_lan()
                print("[MP-HS] host: LAN room open, waiting for the guest...")
        elif r == "lan-guest":
                res = net.join_lan("127.0.0.1")
        if res != "":
                push_error("[MP-HS] " + r + " join failed: " + res)
                tree.quit(1)
                return
        if r == "lan-host":
                var started: bool = false
                for i in 1500:  # 150 s: headless boots are slow
                        if net.slots.size() >= 2 and not net.in_match:
                                var err: String = net.host_start()
                                if err == "":
                                        started = true
                                        print("[MP-HS] host started the match (engine_i=%d)" % GameConfig.engine_i)
                                        break
                        if i % 100 == 99:
                                print("[MP-HS] host: waiting for the guest (slots=%d, status=%s)" % [net.slots.size(), net.status_text])
                        await tree.create_timer(0.1).timeout
                if not started:
                        push_error("[MP-HS] host never started (slots=%d, status=%s)" % [net.slots.size(), net.status_text])
                        tree.quit(1)
                        return
        t0 = Time.get_ticks_msec()
        while Time.get_ticks_msec() - t0 < 240000:
                await tree.create_timer(1.0).timeout
                if net.in_match and net.go and (net.is_host or net.hs_deltas_in > 0):
                        break
        if not (net.in_match and net.go):
                push_error("[MP-HS] %s: the match never started flowing (in_match=%s go=%s status=%s)" % [role, str(net.in_match), str(net.go), net.status_text])
                tree.quit(1)
                return
        print("[MP-HS] %s: the match flows (t=%ds, hs_mode=%s)" % [role, (Time.get_ticks_msec() - t0) / 1000, str(net.hs_mode)])
        report_at = Time.get_ticks_msec()
        var watch_t0: int = Time.get_ticks_msec()
        while Time.get_ticks_msec() - watch_t0 < 40000:
                await tree.create_timer(0.5).timeout
                if not net.in_match or not net.go:
                        continue
                gap_max = maxf(gap_max, net.hs_last_t)
                if net.hold_who != "":
                        holds_seen += 1
                var world: GameWorld = main.get("world")  # re-read: a keyframe restore replaces the world
                if world != null and is_instance_valid(world):
                        var gt: float = world.game_time
                        gt_min = gt if gt_min < 0.0 else minf(gt_min, gt)
                        gt_max = gt if gt_max < 0.0 else maxf(gt_max, gt)
                if Time.get_ticks_msec() - report_at >= 10000:
                        report_at = Time.get_ticks_msec()
                        if net.is_host:
                                var hw: GameWorld = main.get("world")
                                var hu: int = (hw.army.units.size()) if hw != null and is_instance_valid(hw) and hw.army != null else -1
                                print("[MP-HS] %s seq=%d out=%d build_ms=%.1f fx_buf=%d pending=%d host_units=%d" % [
                                        role, net.hs_seq, net.hs_deltas_out, net.hs_build_ms, net._hs_fx.size(), net._pending.size(), hu])
                        else:
                                var units: int = 0
                                var w2: GameWorld = main.get("world")
                                if w2 != null and is_instance_valid(w2) and w2.army != null:
                                        units = w2.army.units.size()
                                print("[MP-HS] %s seq=%d in=%d apply_ms=%.1f gap=%.1f units=%d gt=%.1f" % [
                                        role, net.hs_seq, net.hs_deltas_in, net.hs_apply_ms, gap_max, units, w2.game_time if w2 != null and is_instance_valid(w2) else -1.0])
        # ---- verdict
        var ok: bool = net.in_match and net.go and net.hs_mode
        if net.is_host:
                ok = ok and net.hs_deltas_out >= 5
                print("[MP-HS] host bytes_out=%d KiB over %d deltas (avg %d B)" % [net.hs_bytes_out / 1024, net.hs_deltas_out, net.hs_bytes_out / maxi(1, net.hs_deltas_out)])
                # keep the match alive until the guest has judged the stream: quitting now
                # would end the guest's window mid-measurement (an artificial drought + go=false)
                for i in 600:
                        if FileAccess.file_exists(GUEST_RESULT_FILE):
                                break
                        await tree.create_timer(0.5).timeout
        else:
                var cities2: int = 0
                var w3: GameWorld = main.get("world")
                if w3 != null and is_instance_valid(w3):
                        cities2 = w3.cities.size()
                ok = ok and net.hs_deltas_in >= 5 and cities2 > 0 and gt_max > gt_min and holds_seen == 0
                print("[MP-HS] guest deltas_in=%d apply_ms=%.1f gap_max=%.1f cities=%d holds=%d gt=[%.1f..%.1f] fx_seen=%d" % [
                        net.hs_deltas_in, net.hs_apply_ms, gap_max, cities2, holds_seen, gt_min, gt_max, fx_seen])
                var rf: FileAccess = FileAccess.open(GUEST_RESULT_FILE, FileAccess.WRITE)
                if rf != null:
                        rf.store_line("ok=%s" % str(ok))
                        rf.close()
        print("[MP-HS] RESULT %s: go=%s hs=%s seq=%d in=%d out=%d gap_max=%.2f holds=%d apply_ms=%.1f" % [
                role, str(net.go), str(net.hs_mode), net.hs_seq, net.hs_deltas_in, net.hs_deltas_out, gap_max, holds_seen, net.hs_apply_ms])
        if ok:
                print("[MP-HS] PASS ", role)
                tree.quit(0)
        else:
                push_error("[MP-HS] FAIL " + role)
                tree.quit(1)
