import csv, json
from pathlib import Path

base = Path('tools/perf/results/campaign-official-01')
MB = 1024 * 1024

def rows(path):
    with open(path, newline='', encoding='utf-8') as f:
        return list(csv.DictReader(f))

print("== C interactions: timeline (cpu_total_s cumulative) ==")
r = rows(base/'C-interactions'/'C-interactions.csv')
prev = None
for row in r:
    cpu = float(row['cpu_total_s'])
    if prev is None:
        d = 0.0
    else:
        d = (cpu - prev) * 1000
    prev = cpu
    el = float(row['elapsed_s'])
    if el < 12 or el > 55:
        print(f"  t={el:6.1f}s dCPU={d:7.2f}ms row_cpu%={row['cpu_pct_core']:>7} ws={int(row['ws_bytes'])/MB:6.2f} commit={int(row['commit_bytes'])/MB:6.2f} pf_delta={row['pagefaults_delta']}")
print()

print("== D follow: timeline ==")
r = rows(base/'D-follow'/'D-follow.csv')
prev = None
for row in r:
    cpu = float(row['cpu_total_s'])
    d = 0.0 if prev is None else (cpu-prev)*1000
    prev = cpu
    el = float(row['elapsed_s'])
    if el < 10 or el > 40:
        print(f"  t={el:6.1f}s dCPU={d:7.2f}ms row_cpu%={row['cpu_pct_core']:>7} ws={int(row['ws_bytes'])/MB:6.2f} commit={int(row['commit_bytes'])/MB:6.2f}")
print()

print("== F coldstart snapshots ==")
for f in ['snapshot-t+1,5.json', 'snapshot-t+3.json', 'snapshot-t+13.json', 'snapshot-t+25.json']:
    s = json.load(open(base/'F-coldstart'/f, encoding='utf-8'))
    c = s['counters']
    print(f"  {f}: uptime={s['target']['uptime_s']:.3f}s ws={c['ws_bytes']/MB:.2f}MiB commit={c['commit_bytes']/MB:.2f} pw={c['private_ws_bytes']/MB:.2f} cpu={c['cpu_total_seconds']:.4f} peak={c['peak_ws_bytes']/MB:.2f} handles={c['handles']} threads={c['threads']}")

print()
print("== E cycles snapshots ==")
for f in ['snapshot-before-E.json', 'snapshot-after-E.json']:
    s = json.load(open(base/'E-cycles'/f, encoding='utf-8'))
    c = s['counters']
    print(f"  {f}: uptime={s['target']['uptime_s']:.1f} ws={c['ws_bytes']/MB:.2f} commit={c['commit_bytes']/MB:.2f} pw={c['private_ws_bytes']/MB:.2f} cpu={c['cpu_total_seconds']} handles={c['handles']} gdi={c['gdi_objects']} user={c['user_objects']} threads={c['threads']}")

print()
print("== E2 5 cycles official-01 ==")
for f in ['snapshot-before-E2.json', 'snapshot-after-E2.json']:
    s = json.load(open(base/'E2-recreate'/f, encoding='utf-8'))
    c = s['counters']
    print(f"  {f}: uptime={s['target']['uptime_s']:.1f} ws={c['ws_bytes']/MB:.2f} commit={c['commit_bytes']/MB:.2f} pw={c['private_ws_bytes']/MB:.2f} cpu={c['cpu_total_seconds']} handles={c['handles']} gdi={c['gdi_objects']} user={c['user_objects']} threads={c['threads']}")

print()
print("== snapshots W/A/B/A->before transitions ==")
for label, dirn, fn in [("W before", 'W-watch', 'snapshot-before-W-watch.json'), ("W after", 'W-watch', 'snapshot-after-W-watch.json'),
                        ("A before", 'A-watch', 'snapshot-before-A-watch.json'), ("A after", 'A-watch', 'snapshot-after-A-watch.json'),
                        ("B before", 'B-watch-expanded', 'snapshot-before-B-watch-expanded.json'), ("B after", 'B-watch-expanded', 'snapshot-after-B-watch-expanded.json')]:
    s = json.load(open(base/dirn/fn, encoding='utf-8'))
    c = s['counters']
    print(f"  {label}: cpu={c['cpu_total_seconds']} ws={c['ws_bytes']/MB:.2f} pw={c['private_ws_bytes']/MB:.2f} commit={c['commit_bytes']/MB:.2f} handles={c['handles']} gdi={c['gdi_objects']} user={c['user_objects']} thr={c['threads']} pf={c['page_faults']} uptime={s['target']['uptime_s']:.1f}")
