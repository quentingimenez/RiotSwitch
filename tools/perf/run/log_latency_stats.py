import re, json, statistics
from datetime import datetime
from pathlib import Path
import os

log_path = Path(os.environ['LOCALAPPDATA']) / 'RiotSwitch' / 'logs' / 'app.log'
text = log_path.read_text(encoding='utf-8-sig', errors='replace').splitlines()

ts_re = re.compile(r'^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d+)\+00:00 \[(\w+)\] (.*)$')
entries = []
for line in text:
    m = ts_re.match(line)
    if not m:
        continue
    ts = datetime.fromisoformat(m.group(1))
    entries.append((ts, m.group(2), m.group(3).strip()))

# paires détection -> overlay affiché
creations = []
pending_detect = None
pending_create = None
for ts, lvl, msg in entries:
    if 'Tracker : fenêtre Riot Client détectée' in msg:
        pending_detect = ts
        pending_create = None
    elif msg.startswith("WatchContext : création de l'overlay"):
        pending_create = ts
    elif msg.startswith('WatchContext : overlay affiché'):
        if pending_detect is not None:
            creations.append({
                'detect_utc': pending_detect.isoformat(),
                'created_utc': (pending_create or pending_detect).isoformat(),
                'shown_utc': ts.isoformat(),
                'detect_to_create_ms': ((pending_create or pending_detect) - pending_detect).total_seconds() * 1000,
                'create_to_shown_ms': (ts - (pending_create or pending_detect)).total_seconds() * 1000,
                'detect_to_shown_ms': (ts - pending_detect).total_seconds() * 1000,
            })
        pending_detect = None
        pending_create = None

def pct(vals, p):
    vals = sorted(vals)
    if not vals:
        return None
    k = (len(vals) - 1) * p / 100
    lo = int(k)
    hi = min(lo + 1, len(vals) - 1)
    return vals[lo] + (vals[hi] - vals[lo]) * (k - lo)

d2s = [c['detect_to_shown_ms'] for c in creations]
d2c = [c['detect_to_create_ms'] for c in creations]
c2s = [c['create_to_shown_ms'] for c in creations]
summary = {
    'n': len(creations),
    'detect_to_shown_ms': {'min': min(d2s), 'p50': pct(d2s, 50), 'p90': pct(d2s, 90), 'p99': pct(d2s, 99), 'max': max(d2s), 'mean': statistics.fmean(d2s)} if d2s else None,
    'detect_to_create_ms': {'min': min(d2c), 'p50': pct(d2c, 50), 'p90': pct(d2c, 90), 'max': max(d2c), 'mean': statistics.fmean(d2c)} if d2c else None,
    'create_to_shown_ms': {'min': min(c2s), 'p50': pct(c2s, 50), 'p90': pct(c2s, 90), 'max': max(c2s), 'mean': statistics.fmean(c2s)} if c2s else None,
}
old = [c for c in creations if c['detect_utc'] < '2026-11-11T01:50']
new = [c for c in creations if c['detect_utc'] >= '2026-11-11T01:50']
def block(items):
    v = [c['detect_to_shown_ms'] for c in items]
    if not v:
        return None
    return {'n': len(v), 'min': min(v), 'p50': pct(v, 50), 'p90': pct(v, 90), 'max': max(v), 'mean': statistics.fmean(v)}
summary['pre_campaign'] = block(old)
summary['campaign'] = block(new)
print(json.dumps(summary, indent=1, ensure_ascii=False))

out = Path('tools/perf/results/log-overlay-creation-stats-full.json')
out.write_text(json.dumps({'summary': summary, 'creations': creations}, indent=1, ensure_ascii=False), encoding='utf-8')
print('saved', out)
