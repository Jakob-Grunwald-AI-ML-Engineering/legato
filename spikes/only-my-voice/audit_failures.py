"""Energy audit, not VAD or word accuracy, of rejected held-out sentence windows."""
import array
import json
import math
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent


def main() -> None:
    manifest = json.loads(Path(sys.argv[1]).read_text())
    raw = json.loads((ROOT / "results/scores-sentences-cpu.json").read_text())
    summary = json.loads((ROOT / "results/summary-sentences-cpu.json").read_text())
    cutoffs = {row["seconds"]: row["duration_calibrated"][1]["threshold"] for row in summary["windows"]}
    results = []
    for row in raw["trials"]:
        duration = row["window_seconds"]
        score = row["scores"][row["speaker_index"]]
        if row["split"] != "test" or score >= cutoffs[duration]:
            continue
        source = manifest[row["speaker"]]["0"][0]
        command = ["ffmpeg", "-v", "error", "-i", source, "-ss", str(row["offset_seconds"]),
                   "-t", str(duration), "-f", "f32le", "-ar", "16000", "-ac", "1", "-"]
        samples = array.array("f", subprocess.check_output(command))
        rms = math.sqrt(sum(sample*sample for sample in samples)/len(samples))
        frame_rms = [math.sqrt(sum(sample*sample for sample in samples[i:i+320])/len(samples[i:i+320]))
                     for i in range(0,len(samples),320)]
        results.append({"speaker": row["speaker"],"offset_seconds":row["offset_seconds"],
            "duration_seconds":duration,"cosine":score,"threshold":cutoffs[duration],
            "rms_dbfs":20*math.log10(max(rms,1e-12)),"peak":max(abs(sample) for sample in samples),
            "fraction_20ms_frames_above_minus35_dbfs":sum(value>10**(-35/20) for value in frame_rms)/len(frame_rms),
            "fraction_20ms_frames_above_minus40_dbfs":sum(value>10**(-40/20) for value in frame_rms)/len(frame_rms)})
    (ROOT / "results/rejected-window-energy.json").write_text(json.dumps(results,indent=2)+"\n")
    print(json.dumps(results,indent=2))


if __name__ == "__main__":
    main()
