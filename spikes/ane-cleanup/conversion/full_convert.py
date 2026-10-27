"""Run the pinned upstream converter, with no training or production writes."""
import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

import psutil
from huggingface_hub import (
    snapshot_download,  # pyright: ignore[reportUnknownVariableType] - unused upstream parameter types are incomplete
)

from ane_conversion.provenance import verify_upstream

SOURCE_ID = "Qwen/Qwen3-0.6B"
SOURCE_REVISION = "c1899de289a04d12100db370d81485cdf75e47ca"
ANEMLL_REVISION = "f4ad26d061dc2e426faa19f81c367343bdeb9f0d"
REQUIRED_FREE = 11 * 1024 ** 3  # 8 GiB work budget plus 3 GiB reserve.


def file_sha256(path: Path) -> str:
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--upstream", type=Path, required=True)
    parser.add_argument("--output", type=Path, default=Path("artifacts/qwen3-06b-full"))
    parser.add_argument("--precision", choices=["lut6", "fp16"], default="lut6")
    parser.add_argument("--source-existing", type=Path, help="Reuse a snapshot after verifying its exact safetensors hash")
    args = parser.parse_args()
    upstream, output = args.upstream.resolve(), args.output.resolve()
    script = upstream / "anemll/utils/convert_model.sh"
    if not script.is_file():
        raise ValueError("upstream must be the pinned ANEMLL checkout")
    verified_upstream = verify_upstream(upstream)
    output.mkdir(parents=True, exist_ok=True)
    free = shutil.disk_usage(output).free
    if free < REQUIRED_FREE:
        raise RuntimeError(f"Refusing conversion: need {REQUIRED_FREE} free bytes, found {free}")
    source = args.source_existing.resolve() if args.source_existing else output / "source"
    converted = output / "converted"
    lut = "6,4" if args.precision == "lut6" else ""
    hashes = {str(path.relative_to(upstream)): file_sha256(path)
              for path in [script, upstream / "anemll/ane_converter/qwen_converter.py", upstream / "anemll/models/qwen_model.py"]}
    record: dict[str, object] = {"source_id": SOURCE_ID, "source_revision": SOURCE_REVISION,
        "upstream_revision": verified_upstream["revision"], "upstream_pin_verified": True,
        "upstream_verified_closure": verified_upstream, "upstream_file_sha256": hashes, "python": sys.version,
        "free_bytes_before": free, "status": "downloading", "training": False, "runner_pid": os.getpid(),
        "precision": args.precision, "source_reused": args.source_existing is not None,
        "quantization": {"embeddings": "fp16", "ffn": lut or "fp16", "lmhead": lut or "fp16"},
        "context": 2048, "batch": 64, "chunks": 2,
        "environment_note": "locked torch2.7.0; upstream requirements specify torch2.5.0"}
    report = output / "conversion.json"
    report.write_text(json.dumps(record, indent=2) + "\n")
    child: subprocess.Popen[bytes] | None = None
    try:
        tick = time.monotonic()
        if args.source_existing is None:
            snapshot_download(SOURCE_ID, revision=SOURCE_REVISION, local_dir=source,
                          allow_patterns=["config.json", "generation_config.json", "model.safetensors", "tokenizer*", "vocab.json", "merges.txt", "LICENSE", "README.md"], max_workers=2)
        if file_sha256(source / "model.safetensors") != "f47f71177f32bcd101b7573ec9171e6a57f4f4d31148d38e382306f42996874b":
            raise ValueError("source checkpoint hash does not match the pinned Qwen snapshot")
        record["download_seconds"] = time.monotonic() - tick
        record["source_file_sha256"] = {str(path.relative_to(source)): file_sha256(path)
                                        for path in source.iterdir() if path.is_file()}
        command = ["bash", str(script), "--model", str(source), "--output", str(converted), "--context", "2048",
                   "--batch", "64", "--lut2", lut, "--lut3", lut, "--chunk", "2", "--prefix", "qwen",
                   "--skip-check", "--skip-anemll-dedup"]
        # The locked environment is already checked; avoid upstream auto-venv and optional Rust dedup downloads.
        env = os.environ.copy()
        scratch = output / "tmp"
        scratch.mkdir(exist_ok=True)
        env.update({"ANEMLL_AUTO_VENV": "0", "PYTHONDONTWRITEBYTECODE": "1", "TMPDIR": str(scratch),
                    "PYTHONPYCACHEPREFIX": str(scratch / "verified-source-pycache"),
                    "OMP_NUM_THREADS": "2", "MKL_NUM_THREADS": "2", "PYTHONUNBUFFERED": "1"})
        record.update({"command": command, "status": "converting"})
        report.write_text(json.dumps(record, indent=2) + "\n")
        started, peak_rss = time.monotonic(), 0
        with (output / "upstream.log").open("w") as log:
            child = subprocess.Popen(command, cwd=upstream, env=env, stdout=log, stderr=subprocess.STDOUT)
            record["child_pid"] = child.pid
            report.write_text(json.dumps(record, indent=2) + "\n")
            process = psutil.Process(child.pid)
            while child.poll() is None:
                try:
                    family = [process, *process.children(recursive=True)]
                    resident = sum(member.memory_info().rss for member in family if member.is_running())
                    peak_rss = max(peak_rss, resident)
                except psutil.NoSuchProcess:
                    pass
                time.sleep(0.5)
        record.update({"exit_code": child.returncode, "conversion_seconds": time.monotonic() - started,
            "sampled_process_family_peak_rss_bytes": peak_rss, "rss_sample_seconds": 0.5,
            "free_bytes_after": shutil.disk_usage(output).free,
            "artifact_bytes": sum(path.stat().st_size for path in output.rglob("*") if path.is_file()),
            "status": "converted_unvalidated" if child.returncode == 0 else "failed", "parity": "not_run", "device_measurement": False})
        report.write_text(json.dumps(record, indent=2) + "\n")
        print(json.dumps(record, indent=2))
        return child.returncode
    except Exception as error:
        record.update({"status": "failed", "error_type": type(error).__name__, "error": str(error),
                       "child_may_still_run": child is not None and child.poll() is None})
        report.write_text(json.dumps(record, indent=2) + "\n")
        print(json.dumps(record, indent=2))
        return 1



if __name__ == "__main__":
    raise SystemExit(main())
