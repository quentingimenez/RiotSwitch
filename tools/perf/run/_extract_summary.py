import json, glob, os, sys
cdir = r"C:\Users\SuperKnacky\code\RiotSwitch\tools\perf\results\campaign-official-01"
s = json.load(open(os.path.join(cdir, "campaign-summary.json"), encoding="utf-8-sig"))
if isinstance(s, dict) and "phases" in s:
    ph = s["phases"]
else:
    ph = s
print("=== ENV ===")
env = s.get("environment", {})
print({k: env.get(k) for k in ("generated_at_utc","dpi_scale","logical_cpus","probe_target_budget","sampler_budget","watcher_final_pid") if isinstance(s, dict)} if isinstance(s, dict) else "n/a")
print(json.dumps(env, ensure_ascii=False)[:1200])
print("\n=== TRANSITIONS / PHASES ===")
def walk(o, depth=0, name="root"):
    pass
# phases likely list of dicts
if isinstance(ph, list):
    for item in ph:
        print(json.dumps(item, ensure_ascii=False)[:3000])
        print("---")
elif isinstance(ph, dict):
    for k, v in ph.items():
        print("###", k)
        print(json.dumps(v, ensure_ascii=False)[:3000])
        print("---")
print("\n=== FINAL ===")
print(json.dumps(s.get("final_state"), ensure_ascii=False))
print(json.dumps(s.get("final_foreground_transition"), ensure_ascii=False)[:800])
