import json
from pathlib import Path
p = Path('tools/perf/results/campaign-official-01/campaign-summary.json')
d = json.load(open(p, encoding='utf-8-sig'))
print("summary keys:", list(d.keys()))

def walk(obj, prefix=''):
    if isinstance(obj, dict):
        for k, v in obj.items():
            walk(v, f"{prefix}.{k}" if prefix else k)
    elif isinstance(obj, list) and obj and isinstance(obj[0], (dict, list)):
        walk(obj[0], prefix + '[0]')

# phases list
for phase in d.get('phases', []):
    print("PHASE", phase.get('phase') or phase.get('name'), "keys:", list(phase.keys()))
    for k, v in phase.items():
        if isinstance(v, (dict, list)):
            s = json.dumps(v, ensure_ascii=False)
            if len(s) > 2500 and k not in ('samples',):
                print(f"  {k}: <{type(v).__name__} len {len(s)}>")
                continue
            print(f"  {k}: {s}")
        else:
            print(f"  {k}: {v}")
    print()

