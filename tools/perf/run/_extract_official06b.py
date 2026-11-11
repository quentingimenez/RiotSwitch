import json, os, statistics

base = r"tools/perf/results/campaign-official-06"
s = json.load(open(os.path.join(base, "campaign-summary.json"), encoding="utf-8-sig"))
print("phases:", [p.get("phase") for p in s.get("phases", [])])
print("final_state:", json.dumps(s.get("final_state"), ensure_ascii=False)[:300])

for p in s.get("phases", []):
    name, val = p.get("phase"), p.get("value")
    if name == "E_cycles":
        print("\nE_cycles keys:", list(val.keys()))
        for k in ("total_ms", "expand_ms", "collapse_ms", "snapshot_before", "snapshot_after", "cpu_ms_per_cycle", "cycles"):
            v = val.get(k)
            if k == "cycles" and isinstance(v, list):
                # aggregated from cycle entries
                ex = [c["expand_ms"] for c in v]
                co = [c["collapse_ms"] for c in v]
                print("cycles n=%d expand min/mean/max=%.3f/%.3f/%.3f collapse min/mean/max=%.3f/%.3f/%.3f" % (
                    len(v), min(ex), statistics.mean(ex), max(ex), min(co), statistics.mean(co), max(co)))
            elif k in ("expand_ms", "collapse_ms") and isinstance(v, dict):
                print(" ", k, "min/mean/max", v.get("min"), v.get("mean"), v.get("max"))
            elif k != "cycles":
                print(" ", k, "=", json.dumps(v, ensure_ascii=False)[:350] if isinstance(v, (dict, list)) else v)
    if name in ("A_watch_transition", "B_watch_transition", "F_coldstart"):
        print("\n==", name, "==")
        if name == "F_coldstart":
            print(" fg_transition:", json.dumps(val.get("foreground_transition"), ensure_ascii=False)[:400])
            snap = val.get("snapshots", [])
            print(" snapshots:", [(x.get("label"), x.get("uptime_s"), round(x.get("ws_bytes", 0) / 1048576, 2), round(x.get("commit_bytes", 0) / 1048576, 2), round(x.get("private_ws_bytes", 0) / 1048576, 2), x.get("cpu_total_s")) for x in snap])
        else:
            print(json.dumps(val, ensure_ascii=False)[:600])
