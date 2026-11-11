import json, os

base = r"tools/perf/results/campaign-official-06"
d = json.load(open(os.path.join(base, "analyze-summary.json"), encoding="utf-8"))
for r in d["runs"]:
    c, m, h, t = r["cpu"], r["memory_mib"], r["handles"], r["threads"]
    print("%-8s dur=%.1fs  cpu_agg=%.4f%%core (%.4f%%mach) total=%.5fs p50=%s p95=%.3f max=%.3f | WS min/p50/max=%.2f/%.2f/%.2f  pw=%.2f commit=%.2f peak=%.2f | H=%.0f gdi=%.0f user=%.0f thr=%.0f trims=%d" % (
        r["label"], r["duration_kept_s"],
        c["aggregate_pct_one_core"], c["aggregate_pct_machine"], c["total_cpu_s_kept"],
        c["stats_row_pct_one_core"]["p50"], c["stats_row_pct_one_core"]["p95"], c["stats_row_pct_one_core"]["max"],
        m["ws"]["min"], m["ws"]["p50"], m["ws"]["max"], m["private_ws"]["p50"], m["commit"]["p50"], m["peak_ws"]["p50"],
        h["p50"], r["gdi"]["p50"], r["user"]["p50"], t["p50"], len(m["trims_detected"])))

print()
s = json.load(open(os.path.join(base, "campaign-summary.json"), encoding="utf-8-sig"))
print("keys:", list(s.keys()))
print("final:", json.dumps(s.get("final_state"), ensure_ascii=False)[:400])
for ph in s.get("phases", []):
    name = ph.get("phase")
    val = ph.get("value")
    if name in ("E_cycles", "E2_recreate", "F_coldstart"):
        print("\n==", name, "==")
        print(json.dumps(val, ensure_ascii=False, indent=1)[:5000])
