#!/usr/bin/env python3
"""Analyse des CSV du sampler de la campagne RiotSwitch.

Entree : un ou plusieurs couples label=chemin.csv (CSV produit par
tools/perf/sampler/ProcessSampler.ps1, 15 colonnes, decimaux invariants).

Sortie : JSON de synthese par etat + un JSON global des comparaisons.

Definitions (documentees dans le rapport) :
- CPU % d'un coeur = (cpu_total_s[dernier] - cpu_total_s[premier]) /
                     (elapsed_s[dernier] - elapsed_s[premier]) * 100
  calcule sur les lignes retenues apres warmup, PAS sur une moyenne de lignes
  (evite le biais des intervalles irreguliers).
- CPU % machine = % coeur / nombre de processeurs logiques.
- warmup : les N premiers echantillons sont exclus du calcul CPU (bruit de
  demarrage des processus de mesure) ; les stats memoire les incluent par
  defaut car elles ne dependent pas du demarrage (option --include-warmup-mem).
- private_ws_bytes = working set prive (QueryWorkingSet) ; commit_bytes =
  PagefileUsage. Les deux sont distincts.
- trim detecte : chute de ws_bytes > 8 Mio entre deux echantillons.
- pic CPU : echantillon > --spike-threshold % coeur (defaut 5).

Usage :
  python analyze.py --out tools/perf/results/analysis.json \
      --run W_launcher=tools/perf/results/w-launcher-....csv \
      --run W_watch=... --warmup 2
"""
from __future__ import annotations

import argparse
import csv
import json
import math
import os
import statistics
import sys
from datetime import datetime, timezone


def load_csv(path: str) -> list[dict]:
    rows: list[dict] = []
    with open(path, "r", encoding="utf-8-sig", newline="") as fh:
        reader = csv.DictReader(fh)
        for raw in reader:
            row: dict[str, float] = {}
            for key, value in raw.items():
                if key is None:
                    continue
                value = (value or "").strip()
                if value == "":
                    row[key] = float("nan")
                    continue
                try:
                    row[key] = float(value)
                except ValueError:
                    row[key] = value  # timestamp_utc
            rows.append(row)
    return rows


def as_float(value, default=float("nan")) -> float:
    if isinstance(value, (int, float)):
        return float(value)
    return default


def finite(values: list[float]) -> list[float]:
    return [v for v in values if isinstance(v, (int, float)) and math.isfinite(v)]


def stats(values: list[float]) -> dict | None:
    values = finite(values)
    if not values:
        return None
    values_sorted = sorted(values)
    n = len(values_sorted)

    def pct(p: float) -> float:
        if n == 1:
            return values_sorted[0]
        rank = (p / 100.0) * (n - 1)
        lo = int(math.floor(rank))
        hi = int(math.ceil(rank))
        if lo == hi:
            return values_sorted[lo]
        frac = rank - lo
        return values_sorted[lo] * (1 - frac) + values_sorted[hi] * frac

    return {
        "n": n,
        "min": min(values_sorted),
        "p50": pct(50),
        "mean": sum(values_sorted) / n,
        "p95": pct(95),
        "max": max(values_sorted),
    }


def summarize(path: str, label: str, warmup: int, spike_threshold: float) -> dict:
    rows = load_csv(path)
    if not rows:
        return {"label": label, "csv": path, "error": "CSV vide"}

    cpu_all = [as_float(r.get("cpu_pct_core")) for r in rows]
    elapsed_all = [as_float(r.get("elapsed_s")) for r in rows]
    cpu_total_all = [as_float(r.get("cpu_total_s")) for r in rows]

    warm = min(max(0, warmup), max(0, len(rows) - 2))
    kept = rows[warm:]
    kept_cpu_total = [as_float(r.get("cpu_total_s")) for r in kept]
    kept_elapsed = [as_float(r.get("elapsed_s")) for r in kept]
    cpu_series = [as_float(r.get("cpu_pct_core")) for r in kept]
    cpu_series = finite(cpu_series)

    def window_mean(values: list[float]) -> float | None:
        total = sum(values)
        if not any(math.isfinite(v) for v in values):
            return None
        return total / len(values)

    duration_s = None
    cpu_pct_core = None
    cpu_pct_machine = None
    if len(kept) >= 2:
        first_total = as_float(kept[0].get("cpu_total_s"))
        last_total = as_float(kept[-1].get("cpu_total_s"))
        first_elapsed = as_float(kept[0].get("elapsed_s"))
        last_elapsed = as_float(kept[-1].get("elapsed_s"))
        if all(map(math.isfinite, [first_total, last_total, first_elapsed, last_elapsed])) and last_elapsed > first_elapsed:
            duration_s = last_elapsed - first_elapsed
            cpu_pct_core = (last_total - first_total) / duration_s * 100.0
            cpu_pct_machine = cpu_pct_core / os.cpu_count() if os.cpu_count() else None

    # nombre de "pas" CPU dans le CSV (compat)
    cpu_pct_series_mean = window_mean(cpu_series)

    # 3.2 memoire : toutes les lignes (ou apres warmup)
    def col(name: str) -> list[float]:
        return [as_float(r.get(name)) for r in kept]

    def to_mib(values: list[float]) -> list[float]:
        return [v / (1024.0 * 1024.0) for v in finite(values)]

    ws_mib = to_mib(col("ws_bytes"))
    private_ws_mib = to_mib(col("private_ws_bytes"))
    commit_mib = to_mib(col("commit_bytes"))
    peak_ws_mib = to_mib(col("peak_ws_bytes")) if col("peak_ws_bytes") else []
    handles = col("handles")
    gdi = col("gdi")
    user = col("user")
    threads = col("threads")

    # trims : chute de WS > 8 Mio
    trims = []
    for idx in range(1, len(ws_mib)):
        drop = ws_mib[idx - 1] - ws_mib[idx]
        if drop > 8.0:
            trims.append({
                "sample": idx + warm,
                "timestamp_utc": kept[idx].get("timestamp_utc"),
                "ws_before_mib": round(ws_mib[idx - 1], 2),
                "ws_after_mib": round(ws_mib[idx], 2),
                "drop_mib": round(drop, 2),
                "cpu_pct_core": round(as_float(kept[idx].get("cpu_pct_core")), 3),
            })

    spikes = []
    for idx, value in enumerate(cpu_series):
        if math.isfinite(value) and value > spike_threshold:
            spikes.append({
                "sample": idx + warm,
                "timestamp_utc": kept[idx].get("timestamp_utc"),
                "cpu_pct_core": round(value, 3),
            })

    total_kept = finite([as_float(r.get("cpu_total_s")) for r in kept])
    timestamps = [r.get("timestamp_utc") for r in rows if r.get("timestamp_utc")]
    return {
        "label": label,
        "csv": path,
        "started_utc": timestamps[0] if timestamps else None,
        "ended_utc": timestamps[-1] if timestamps else None,
        "samples_total": len(rows),
        "samples_kept": len(kept),
        "warmup_excluded": warm,
        "duration_kept_s": round(duration_s, 3) if duration_s else None,
        "cpu": {
            "aggregate_pct_one_core": round(cpu_pct_core, 4) if cpu_pct_core is not None else None,
            "aggregate_pct_machine": round(cpu_pct_machine, 4) if cpu_pct_machine is not None else None,
            "mean_row_pct_one_core": round(cpu_pct_series_mean, 4) if cpu_pct_series_mean is not None else None,
            "stats_row_pct_one_core": tied_stats(cpu_series),
            "total_cpu_s_kept": round(total_kept[-1] - total_kept[0], 4) if len(total_kept) >= 2 else None,
            "spikes_above_threshold": spikes,
        },
        "memory_mib": {
            "ws": tied_stats(ws_mib),
            "private_ws": tied_stats(private_ws_mib),
            "commit": tied_stats(commit_mib),
            "peak_ws": tied_stats(peak_ws_mib),
            "trims_detected": trims,
        },
        "handles": tied_stats(handles),
        "gdi": tied_stats(gdi),
        "user": tied_stats(user),
        "threads": tied_stats(threads),
    }


def tied_stats(values: list[float]) -> dict | None:
    s = stats(values)
    if s is None:
        return None
    return {k: round(v, 4) for k, v in s.items()}


def main() -> int:
    parser = argparse.ArgumentParser(description="Analyse CSV sampler RiotSwitch")
    parser.add_argument("--run", action="append", required=True, help="label=chemin.csv")
    parser.add_argument("--out", required=True)
    parser.add_argument("--warmup", type=int, default=2)
    parser.add_argument("--spike-threshold", type=float, default=5.0)
    args = parser.parse_args()

    results = []
    errors = []
    for spec in args.run:
        if "=" not in spec:
            errors.append(f"spec invalide (attendu label=chemin.csv) : {spec}")
            continue
        label, path = spec.split("=", 1)
        if not os.path.exists(path):
            errors.append(f"fichier introuvable pour {label} : {path}")
            continue
        try:
            results.append(summarize(path, label, args.warmup, args.spike_threshold))
        except Exception as exc:  # noqa: BLE001
            errors.append(f"{label} ({path}) : {exc}")

    payload = {
        "schema": "riotswitch-perf-analysis/1",
        "generated_utc": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        "logical_cpus": os.cpu_count(),
        "warmup_excluded": args.warmup,
        "spike_threshold_pct_core": args.spike_threshold,
        "runs": results,
        "errors": errors,
    }

    out_dir = os.path.dirname(os.path.abspath(args.out))
    if out_dir:
        os.makedirs(out_dir, exist_ok=True)
    with open(args.out, "w", encoding="utf-8", newline="\n") as fh:
        json.dump(payload, fh, ensure_ascii=False, indent=2)
        fh.write("\n")
    print(json.dumps({"ok": not errors, "out": args.out, "runs": len(results), "errors": errors}, ensure_ascii=False))
    return 0 if not errors else 2


if __name__ == "__main__":
    sys.exit(main())
