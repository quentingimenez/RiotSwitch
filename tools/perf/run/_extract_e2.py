import json
from pathlib import Path
MB = 1024 * 1024
def m(x): return f"{x/MB:.2f}"
base = Path('tools/perf/results')
print("== E2 15 cycles : snapshots ==")
vals = {}
for f in ['snapshot-before-E2.json', 'snapshot-after-E2.json']:
    s = json.load(open(base/'campaign-official-02-e2-leak/E2-recreate'/f, encoding='utf-8'))
    cc = s['counters']
    vals[f] = cc
    print(f, "uptime", round(s['target']['uptime_s'], 1), "| cpu_s", cc['cpu_total_seconds'],
          "| ws", m(cc['ws_bytes']), "| pw", m(cc['private_ws_bytes']), "| commit", m(cc['commit_bytes']),
          "| peak", m(cc['peak_ws_bytes']), "| handles", cc['handles'], "| gdi", cc['gdi_objects'],
          "| user", cc['user_objects'], "| threads", cc['threads'], "| pf", cc['page_faults'])
b = vals['snapshot-before-E2.json']
a = vals['snapshot-after-E2.json']
n = 15
print("DELTAS:", "ws MiB", round((a['ws_bytes']-b['ws_bytes'])/MB, 3),
      "pw MiB", round((a['private_ws_bytes']-b['private_ws_bytes'])/MB, 3),
      "commit MiB", round((a['commit_bytes']-b['commit_bytes'])/MB, 3),
      "cpu_s", round(a['cpu_total_seconds']-b['cpu_total_seconds'], 6),
      "pf", a['page_faults']-b['page_faults'],
      "handles", a['handles']-b['handles'], "threads", a['threads']-b['threads'],
      "gdi", a['gdi_objects']-b['gdi_objects'], "user", a['user_objects']-b['user_objects'])
print("PER CYCLE:", "ws KiB", round((a['ws_bytes']-b['ws_bytes'])/n/1024, 1),
      "pw KiB", round((a['private_ws_bytes']-b['private_ws_bytes'])/n/1024, 1),
      "commit KiB", round((a['commit_bytes']-b['commit_bytes'])/n/1024, 1),
      "cpu ms", round((a['cpu_total_seconds']-b['cpu_total_seconds'])*1000/n, 2))
