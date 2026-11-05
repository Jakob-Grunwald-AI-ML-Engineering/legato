"""Summarize local embeddings; calibrate only on take 6, evaluate take 0."""
import argparse
import json
import statistics
from pathlib import Path

ROOT = Path(__file__).resolve().parent


def cosine(a: list[float], b: list[float]) -> float:
    return sum(x*y for x, y in zip(a, b, strict=True))


def rates(rows: list[dict], threshold: float) -> dict[str, float | int]:
    positive = [row["scores"][row["speaker_index"]] for row in rows]
    negative = [score for row in rows for target, score in enumerate(row["scores"]) if target != row["speaker_index"]]
    return {"target_retained": sum(s >= threshold for s in positive)/len(positive),
            "other_rejected": sum(s < threshold for s in negative)/len(negative),
            "target_trials": len(positive), "other_trials": len(negative)}


def worst(rows: list[dict], threshold: float, count: int) -> dict[str, float]:
    return {"worst_target_retained": min(
        sum(row["scores"][i] >= threshold for row in rows if row["speaker_index"] == i)/sum(row["speaker_index"] == i for row in rows)
        for i in range(count)), "worst_other_rejected": min(
        sum(row["scores"][i] < threshold for row in rows if row["speaker_index"] != i)/sum(row["speaker_index"] != i for row in rows)
        for i in range(count))}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input",type=Path)
    parser.add_argument("--output-dir",type=Path,required=True)
    args = parser.parse_args()
    input_path = args.input
    args.output_dir.mkdir(parents=True,exist_ok=True)
    suffix = input_path.name.removeprefix("embeddings-").removeprefix("scores-")
    raw = json.loads(input_path.read_text())
    speaker_count = len(raw["enrollment"])
    rows = raw["trials"]
    compact = {key: value for key,value in raw.items() if key != "trials"}
    compact["trials"] = [{key:value for key,value in row.items() if key != "embedding"} for row in rows]
    (args.output_dir / ("scores-" + suffix)).write_text(json.dumps(compact,indent=2)+"\n")
    calibration = [row for row in rows if row["split"] == "calibration"]
    # Optimize balanced error on calibration, never held-out test; diagnostic only.
    threshold = min((i/100 for i in range(-20, 101)), key=lambda t: 2-rates(calibration,t)["target_retained"]-rates(calibration,t)["other_rejected"])
    results: dict = {"calibrated_threshold": threshold, "selection": "minimum balanced error across calibration windows, equal trial weights",
                     "model_load_seconds": raw["model_load_seconds"], "peak_rss_bytes": raw["peak_rss_bytes"],
                     "user_cpu_seconds": raw["user_cpu_seconds"], "system_cpu_seconds": raw["system_cpu_seconds"],
                     "enrollment": raw["enrollment"], "windows": []}
    test = [row for row in rows if row["split"] == "test"]
    for duration in (0.35, 1.0, 2.0, 3.0):
        selected = [row for row in test if row["window_seconds"] == duration]
        times = sorted(row["inference_ms"] for row in selected)
        cal = [row for row in calibration if row["window_seconds"] == duration]
        choices = [i/100 for i in range(-100, 101)]
        balanced = min(choices, key=lambda t: 2-rates(cal,t)["target_retained"]-rates(cal,t)["other_rejected"])
        safe = max(t for t in choices if rates(cal,t)["target_retained"] >= .99)
        results["windows"].append({"seconds": duration, **rates(selected,threshold),
            "duration_calibrated": [{"operating_point": label,"threshold": cutoff,
                "calibration": rates(cal,cutoff),"test": {**rates(selected,cutoff), **worst(selected,cutoff,speaker_count)}}
                for label,cutoff in (("balanced_error",balanced),("at_least_99pct_calibration_target_retention",safe))],
            "median_inference_ms": statistics.median(times), "p95_inference_ms": times[int(.95*(len(times)-1))],
            "per_target": [{"speaker": profile["speaker"],
                "target_retained": sum(row["scores"][i] >= threshold for row in selected if row["speaker_index"] == i)/sum(row["speaker_index"] == i for row in selected),
                "other_rejected": sum(row["scores"][i] < threshold for row in selected if row["speaker_index"] != i)/sum(row["speaker_index"] != i for row in selected)}
                for i,profile in enumerate(raw["enrollment"])]})
    # Construct ordered sessions from held-out 1s windows, rotate all target/other identities.
    sessions = []
    one = [row for row in test if row["window_seconds"] == 1]
    policies: dict[str,list[dict]] = {"enrollment": [], "automatic_first_voice": [], "dominant_cluster": []}
    for target in range(speaker_count) if "embedding" in one[0] else []:
        for other in range(speaker_count):
            if target == other:
                continue
            t = [row for row in one if row["speaker_index"] == target][:2]
            o = [row for row in one if row["speaker_index"] == other][:3]
            for name, sequence in (("target_first",t+o), ("other_first",o+t)):
                clusters: list[list[dict]] = []
                for row in sequence:
                    scores = [cosine(row["embedding"],cluster[0]["embedding"]) for cluster in clusters]
                    if scores and max(scores) >= threshold:
                        clusters[scores.index(max(scores))].append(row)
                    else:
                        clusters.append([row])
                dominant = max(clusters,key=len)
                for policy in policies:
                    keep = []
                    for row in sequence:
                        if policy == "enrollment":
                            keep.append(row["scores"][target] >= threshold)
                        elif policy == "automatic_first_voice":
                            keep.append(cosine(row["embedding"],sequence[0]["embedding"]) >= threshold)
                        else:
                            keep.append(any(row is member for member in dominant))
                    entry = {"case": name, "target": target, "other": other,
                        "target_retained": sum(k for row,k in zip(sequence,keep) if row["speaker_index"] == target)/len(t),
                        "other_rejected": sum(not k for row,k in zip(sequence,keep) if row["speaker_index"] != target)/len(o)}
                    policies[policy].append(entry)
    results["ordered_sessions"] = {policy: [{"case": case, "sessions": sum(row["case"] == case for row in entries),
        "target_retained": statistics.mean(row["target_retained"] for row in entries if row["case"] == case) if entries else None,
        "other_rejected": statistics.mean(row["other_rejected"] for row in entries if row["case"] == case) if entries else None}
        for case in ("target_first","other_first")] for policy,entries in policies.items()}
    (args.output_dir / ("summary-" + suffix)).write_text(json.dumps(results,indent=2)+"\n")
    print("Per-duration calibration → held-out audio-window rates (not word accuracy)")
    print("Seconds  Operating point    Cutoff  Target retained  Others rejected  Target/other trials")
    for window in results["windows"]:
        for point in window["duration_calibrated"]:
            label = "balanced" if point["operating_point"] == "balanced_error" else "99% cal retention"
            test = point["test"]
            print(f"{window['seconds']:>7.2f}  {label:<17}  {point['threshold']:>6.2f}  "
                  f"{test['target_retained']:>14.1%}  {test['other_rejected']:>15.1%}  "
                  f"{test['target_trials']}/{test['other_trials']}")
    print(f"Pooled calibration cutoff: {threshold:.2f}; JSON top-level window rates and ordered-session comparisons use this cutoff.")
    print("JSON duration_calibrated entries use each duration's own calibration cutoff.")
    if "embedding" not in one[0]:
        print("Ordered-session comparisons not recomputed: score-only input has no embeddings.")
    print(f"Summary: {args.output_dir / ('summary-' + suffix)}")


if __name__ == "__main__":
    main()
