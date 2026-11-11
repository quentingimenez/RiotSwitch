import json, os, glob
cdir = r"C:\Users\SuperKnacky\code\RiotSwitch\tools\perf\results\campaign-official-01"
s = json.load(open(os.path.join(cdir,"campaign-summary.json"), encoding="utf-8-sig"))
ph = s["phases"]
d = {}
for item in ph:
    d[item["phase"]] = item["value"]
print("=== E snapshots / delta ===")
e = d["E_cycles"]
print("before:", json.dumps(e["snapshot_before"], ensure_ascii=False))
print("after :", json.dumps(e["snapshot_after"], ensure_ascii=False))
print("cpu_delta_s:", e.get("cpu_seconds_delta"), "ms_per_cycle:", e.get("cpu_ms_per_cycle"))
print("result total_ms:", e["result"]["total_ms"], "count:", e["result"]["count"])
print()
print("=== D moves summary ===")
for m in d["D_follow"]["moves"]:
    lat = m.get("latency_ms") if "latency_ms" in m else m.get("steps") and None
    print(m.get("delta_x"), m.get("delta_y"), "lat:", m.get("latency_ms"), "changed:", m.get("changed_count"), "restored:", m.get("restored"))
print()
print("=== W/A/B snapshots before/after ===")
for k in ("W_watch","A_watch","B_watch","C_interactions","D_follow"):
    v = d.get(k)
    if v and "snapshot_before" in v:
        print(k, "before:", json.dumps(v["snapshot_before"], ensure_ascii=False))
        print(k, "after :", json.dumps(v["snapshot_after"], ensure_ascii=False))
print()
print("=== PROBE SUMMARIES ===")
for pj in sorted(glob.glob(os.path.join(cdir,"*","probe-*.json"))):
    p = json.load(open(pj, encoding="utf-8-sig"))
    c = p.get("counters", {})
    pc = p.get("probe_cost", {})
    cor = p.get("correlation", {})
    print(os.path.basename(pj))
    print("  dur_s", p.get("duration_actual_s"), "total_events", c.get("total_events"), "eps", round(c.get("events_per_s") or 0,2),
          "check_eps", round(c.get("check_events",{}).get("per_s") or 0,3) if isinstance(c.get("check_events"),dict) else c.get("check_events_per_s"),
          "idobj0_pct", round((c.get("idobject_zero_pct") or 0),2))
    print("  probe_cost:", json.dumps(pc, ensure_ascii=False)[:400])
    print("  corr:", json.dumps(cor, ensure_ascii=False)[:400])
