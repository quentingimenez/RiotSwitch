import json
from pathlib import Path
MB = 1024 * 1024
def m(x): return f"{x/MB:.2f}"

base = Path('tools/perf/results')
d = json.load(open(base/'campaign-official-02-wclean/W-watch/W-watch.json', encoding='utf-8'))
cpu, mem = d['cpu'], d['memory']
print("== W_watch clean ==")
print("samples", d['sample_count'], "duration_s", round(d['duration_actual_s'], 2))
print("CPU %core: mean", round(cpu['mean_pct_one_core'], 4), "p50", round(cpu['p50_pct_one_core'], 4),
      "p95", round(cpu['p95_pct_one_core'], 4), "max", round(cpu['max_pct_one_core'], 4),
      "agg", round(cpu['aggregate_pct_one_core'], 4), "total_s", round(cpu['total_cpu_seconds'], 4),
      "| %machine agg", round(cpu['aggregate_pct_machine'], 4))
for k, label in [('working_set_bytes', 'WS'), ('private_working_set_bytes', 'privWS'), ('commit_bytes', 'commit')]:
    s = mem[k]
    print(label, "min/median/max MiB:", m(s['min']), m(s.get('median', 0)), m(s['max']))
print("peak WS MiB", m(mem['peak_working_set_bytes']['max']),
      "| WS first/last", m(mem['first_ws_bytes']), m(mem['last_ws_bytes']))
pf = d['page_faults']
print("pagefaults", pf['total'], "=", round(pf['per_s'], 2), "/s")
ov = d['sampler_overhead']
print("sampler overhead", round(ov['pct_one_core'], 3), "%core,", round(ov['avg_ms_cpu_per_sample'], 2), "ms/sample")
print("handles", d['handles']['min'], '-', d['handles']['max'], "gdi", d['gdi_objects']['min'], '-', d['gdi_objects']['max'],
      "user", d['user_objects']['min'], '-', d['user_objects']['max'], "threads", d['threads']['min'], '-', d['threads']['max'])
print("io read/write bytes", d['io']['read_bytes_total'], d['io']['write_bytes_total'])
tc = d['threads_cpu']
print("threads coverage %", tc.get('coverage_pct_of_process_cpu'), "top", tc.get('top'))

pr = json.load(open(base/'campaign-official-02-wclean/W-watch/probe-W-watch.json', encoding='utf-8'))
c = pr['counters']
print("== probe W_watch clean ==")
print("total", c['total_events'], "per_s", c['events_per_s'], "idobj0_pct", c.get('idobject_zero_pct'),
      "check", c['check_events'].get('count'), c['check_events'].get('per_s'), "/s",
      "gross", pr['probe_cost'].get('self_cpu_pct_core_gross'),
      "net", pr['probe_cost'].get('self_cpu_pct_core_net'))
print("by_type", [(t.get('name'), t.get('count')) for t in c.get('by_type', []) if t.get('count')])

print("== E2 15 cycles ==")
for f in ['snapshot-before-E2.json', 'snapshot-after-E2.json']:
    s = json.load(open(base/'campaign-official-02-e2-leak/E2-recreate'/f, encoding='utf-8'))
    cc = s['counters']
    print(f, "uptime", round(s['target']['uptime_s'], 1), "cpu_s", cc['cpu_total_seconds'],
          "ws", m(cc['ws_bytes']), "pw", m(cc['private_ws_bytes']), "commit", m(cc['commit_bytes']),
          "peak", m(cc['peak_ws_bytes']), "handles", cc['handles'], "gdi", cc['gdi_objects'],
          "user", cc['user_objects'], "threads", cc['threads'], "pf", cc['page_faults'])
