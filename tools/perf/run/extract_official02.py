"""Dépouille des campagnes official-02 (W clean, E2 x15) et synthèse JSON."""
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1] / "results"


def load(path):
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def mib(n):
    return n / (1024 * 1024)


def show_sampler(name, path):
    d = load(path)
    cpu = d["cpu"]
    mem = d["memory"]
    print(f"== {name} ==")
    print(f"  samples={d['sample_count']} duration={d['duration_actual_s']:.2f}s "
          f"period(mean)={d['sample_period_ms']['mean']:.1f}ms")
    print(f"  CPU one-core: mean={cpu['mean_pct_one_core']:.4f}% p50={cpu['p50_pct_one_core']:.4f}% "
          f"p95={cpu['p95_pct_one_core']:.4f}% max={cpu['max_pct_one_core']:.4f}% "
          f"agg={cpu['aggregate_pct_one_core']:.4f}% total={cpu['total_cpu_seconds']:.4f}s")
    print(f"  CPU machine: mean={cpu['mean_pct_machine']:.4f}% agg={cpu['aggregate_pct_machine']:.4f}%")
    for key, label in [("working_set_bytes", "WS"), ("private_working_set_bytes", "privWS"),
                       ("commit_bytes", "commit")]:
        st = mem[key]
        print(f"  {label}(MiB): min={mib(st['min']):.2f} p50={mib(st['p50']):.2f} "
              f"max={mib(st['max']):.2f}")
    print(f"  peak WS max={mib(mem['peak_working_set_bytes']['max']):.2f} MiB")
    print(f"  handles={d['handles']['min']}-{d['handles']['max']} gdi={d['gdi_objects']['min']}-{d['gdi_objects']['max']} "
          f"user={d['user_objects']['min']}-{d['user_objects']['max']} threads={d['threads']['min']}-{d['threads']['max']}")
    pf = d["page_faults"]
    print(f"  pagefaults total={pf['total']} ({pf['per_s']:.2f}/s)")
    ov = d["sampler_overhead"]
    print(f"  sampler overhead: {ov['pct_one_core']:.3f}% core, {ov['avg_ms_cpu_per_sample']:.2f} ms/sample")
    tc = d.get("threads_cpu") or {}
    if tc.get("included"):
        print(f"  threads: coverage={tc.get('coverage_pct_of_process_cpu')}% top=")
        for t in tc.get("top", []):
            print(f"    {json.dumps(t, ensure_ascii=False)}")
    print()


def show_probe(name, path):
    d = load(path)
    c = d["counters"]
    print(f"== probe {name} ==")
    print(f"  duration={d.get('duration_actual_s')} total_events={c['total_events']} "
          f"events_per_s={c['events_per_s']:.3f} idobject0_pct={c.get('idobject_zero_pct')}")
    active = [f"{t.get('hex', t.get('type_hex', '?'))}:{t['name']}={t['count']}"
              for t in c.get("by_type", []) if t.get("count", 0) > 0]
    print(f"  by_type: {', '.join(active) if active else 'aucun'}")
    ce = c.get("check_events", {})
    print(f"  check_events={ce.get('count')} ({ce.get('per_s')}/s)")
    pc = d.get("probe_cost", {})
    print(f"  probe_cost gross={pc.get('self_cpu_pct_core_gross')} net={pc.get('self_cpu_pct_core_net')} "
          f"target={pc.get('overhead_target_pct_core')} ok={pc.get('overhead_ok')}")
    corr = d.get("correlation", {})
    print(f"  correlation r={corr.get('r_event_rate_vs_sampler_cpu')}")
    print()


def show_snapshot_pair(name, before_path, after_path, cycles):
    b = load(before_path)
    a = load(after_path)
    bc, ac = b["counters"], a["counters"]
    print(f"== {name} ({cycles} cycles) ==")
    print(f"  uptime before={b.get('target', {}).get('uptime_s'):.2f}s after={a.get('target', {}).get('uptime_s'):.2f}s")
    fields = ["cpu_total_seconds", "ws_bytes", "private_ws_bytes", "commit_bytes", "peak_ws_bytes",
              "handles", "gdi_objects", "user_objects", "threads", "page_faults"]
    for f in fields:
        if f in bc:
            print(f"  {f}: before={bc[f]} after={ac[f]} delta={ac[f]-bc[f]}")
    dws = mib(ac["ws_bytes"] - bc["ws_bytes"])
    dpw = mib(ac["private_ws_bytes"] - bc["private_ws_bytes"])
    dcm = mib(ac["commit_bytes"] - bc["commit_bytes"])
    dcpu = ac["cpu_total_seconds"] - bc["cpu_total_seconds"]
    print(f"  PAR CYCLE: ws={dws/cycles*1024:.1f} KiB pw={dpw/cycles*1024:.1f} KiB "
          f"commit={dcm/cycles*1024:.1f} KiB cpu={dcpu*1000/cycles:.2f} ms")
    print()


if __name__ == "__main__":
    w = ROOT / "campaign-official-02-wclean"
    show_sampler("W_watch clean", w / "W-watch" / "W-watch.json")
    show_probe("W_watch clean", w / "W-watch" / "probe-W-watch.json")
    e2 = ROOT / "campaign-official-02-e2-leak" / "E2-recreate"
    show_snapshot_pair("E2 leak", e2 / "snapshot-before-E2.json", e2 / "snapshot-after-E2.json", 15)
