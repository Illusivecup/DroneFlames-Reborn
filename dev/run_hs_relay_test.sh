#!/bin/bash
# HOSTSIM RELAY test runner (v1.2.1): server + host + guest over the real WSS relay
# with a server-side bandwidth throttle in three phases:
#   0-25 s  200 KiB/s  — a weak but working link
#  25-40 s   16 KiB/s  — heavy congestion (skip logic + queue shedding must engage)
#  40-75 s 4000 KiB/s  — relief (the guest must catch up)
# PASS: both instances print [MP-HSR] PASS; the guest never dies / reconnects.

set -u
cd "$(dirname "$0")/.." || exit 1
GODOT="${GODOT:-/home/z/tools/godot}"
OUT=/tmp
rm -f "$OUT/hs_relay_server.log" "$OUT/hs_relay_host.log" "$OUT/hs_relay_guest.log" /tmp/df_room_code_hs /tmp/df_throttle /tmp/df_hsr_guest_result /tmp/df_hs_guest_result
echo 200 > /tmp/df_throttle

echo "[run] starting signal server (throttle 200 KiB/s)..."
"$GODOT" --headless --path . -s res://net/server/signal_server.gd -- --port=19090 --bind=127.0.0.1 --open \
        --throttle=200 --throttle-control=/tmp/df_throttle > "$OUT/hs_relay_server.log" 2>&1 &
SRV=$!
sleep 4

echo "[run] starting host..."
"$GODOT" --headless --path . -- --hs-relay-host --signal-url=ws://127.0.0.1:19090/mp/signal > "$OUT/hs_relay_host.log" 2>&1 &
HOST=$!

# the guest starts as soon as the host's room code appears (max 90 s)
for i in $(seq 1 180); do
        if [ -s /tmp/df_room_code_hs ]; then break; fi
        if ! kill -0 "$HOST" 2>/dev/null; then echo "[run] host died before the room code"; break; fi
        sleep 0.5
done
echo "[run] starting guest..."
"$GODOT" --headless --path . -- --hs-relay-guest --signal-url=ws://127.0.0.1:19090/mp/signal > "$OUT/hs_relay_guest.log" 2>&1 &
GUEST=$!

# wait for the match to start flowing on the host (max 180 s), then run the phases
FLOWED=0
for i in $(seq 1 360); do
        if rg -q "the match flows over the relay" "$OUT/hs_relay_host.log" 2>/dev/null; then FLOWED=1; break; fi
        if ! kill -0 "$HOST" 2>/dev/null; then break; fi
        sleep 0.5
done
if [ "$FLOWED" = "1" ]; then
        echo "[run] match flows: phase 1 (200 KiB/s) for 25 s..."
        sleep 25
        echo 16 > /tmp/df_throttle
        echo "[run] phase 2 (16 KiB/s congestion) for 15 s..."
        sleep 15
        echo 4000 > /tmp/df_throttle
        echo "[run] phase 3 (4000 KiB/s relief) until the test ends..."
else
        echo "[run] WARNING: the match never flowed; phases skipped"
fi

wait "$HOST"; HRC=$?
# the guest quits by itself when the verdict is printed; give it a grace period
for i in $(seq 1 120); do
        if rg -q "\[MP-HSR\] (PASS|FAIL)" "$OUT/hs_relay_guest.log" 2>/dev/null; then break; fi
        if ! kill -0 "$GUEST" 2>/dev/null; then break; fi
        sleep 1
done
sleep 2
kill "$SRV" 2>/dev/null; kill "$GUEST" 2>/dev/null

echo "[run] ===== verdict ====="
rg "\[MP-HSR\] (PASS|FAIL|RESULT|host:|guest:)" "$OUT/hs_relay_host.log" "$OUT/hs_relay_guest.log" 2>/dev/null | sed 's/^[^ ]* //'
rg "out_queue_overflow|throttle ->" "$OUT/hs_relay_server.log" 2>/dev/null | tail -5
if rg -q "\[MP-HSR\] PASS relay-host" "$OUT/hs_relay_host.log" && rg -q "\[MP-HSR\] PASS relay-guest" "$OUT/hs_relay_guest.log"; then
        echo "[run] RELAY TEST: PASS"
        exit 0
fi
echo "[run] RELAY TEST: FAIL (host rc=$HRC)"
exit 1
