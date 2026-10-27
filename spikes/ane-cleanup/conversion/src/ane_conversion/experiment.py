"""Execute a synthetic block export; measurements describe this Mac and these weights only."""
# coremltools/PyTorch NumPy bridges lack complete stubs; contain unknowns at this boundary.
# pyright: reportMissingTypeStubs=false, reportUnknownMemberType=false, reportUnknownVariableType=false, reportUnknownArgumentType=false
import json
import platform
import resource
import shutil
import sys
import tempfile
import time
from collections import Counter
from dataclasses import asdict
from pathlib import Path

import coremltools as ct
import numpy as np
import torch
from coremltools.models.model import MLState
from numpy.typing import NDArray

from .contracts import causal_mask
from .geometry import OUTPUT_ATOL, OUTPUT_RTOL, STATE_ATOL, STATE_RTOL, Geometry, synthetic_weights
from .layout import ANEBlock
from .reference import reference_block

RESERVE_BYTES = 3 * 1024 ** 3
ARTIFACT_BUDGET_BYTES = 192 * 1024 ** 2
type FloatArray = NDArray[np.float16] | NDArray[np.float32] | NDArray[np.float64]


def compare(actual: FloatArray, expected: FloatArray, *, state: bool = False) -> dict[str, float]:
    atol, rtol = (STATE_ATOL, STATE_RTOL) if state else (OUTPUT_ATOL, OUTPUT_RTOL)
    np.testing.assert_allclose(actual, expected, atol=atol, rtol=rtol)
    difference = np.abs(actual.astype(np.float32) - expected.astype(np.float32))
    return {"max_absolute_error": float(difference.max()), "mean_absolute_error": float(difference.mean()), "atol": atol, "rtol": rtol}


def export_block(g: Geometry, weights: dict[str, torch.Tensor], count: int, destination: Path) -> dict[str, object]:
    block = ANEBlock(g, weights, dtype=torch.float16).eval()
    inputs = (torch.zeros((1, g.hidden, 1, count), dtype=torch.float16), torch.zeros((1,), dtype=torch.int32),
              torch.from_numpy(causal_mask(0, count, g.context).astype(np.float16))[None, None])
    started = time.monotonic()
    with torch.no_grad():
        traced = torch.jit.trace(block, inputs, check_trace=False)
    block.reset()
    for name in ("k_cache", "v_cache"):
        getattr(traced, name).zero_()
    model = ct.convert(traced, inputs=[ct.TensorType(name="hidden", shape=inputs[0].shape, dtype=np.float16),
                                     ct.TensorType(name="position", shape=(1,), dtype=np.int32),
                                     ct.TensorType(name="mask", shape=inputs[2].shape, dtype=np.float16)],
                       outputs=[ct.TensorType(name="output", dtype=np.float16)],
                       states=[ct.StateType(wrapped_type=ct.TensorType(shape=g.cache_shape, dtype=np.float16), name=name)  # pyright: ignore[reportArgumentType] - upstream annotates wrapped_type as type, docs/runtime require TensorType
                               for name in ("k_cache", "v_cache")],
                       minimum_deployment_target=ct.target.iOS18, compute_precision=ct.precision.FLOAT16,
                       compute_units=ct.ComputeUnit.CPU_ONLY, convert_to="mlprogram", skip_model_load=True)
    if not isinstance(model, ct.models.MLModel):
        raise TypeError("converter did not return an MLModel")
    model.user_defined_metadata["legato.synthetic"] = "true; one decoder block; not a cleanup model"
    model.save(str(destination))
    return {"seconds": time.monotonic() - started, "bytes": sum(f.stat().st_size for f in destination.rglob("*") if f.is_file())}


def compute_plan(model: ct.models.MLModel, units: ct.ComputeUnit) -> dict[str, object]:
    """Core ML anticipated placement, explicitly not observed dispatch or Instruments proof."""
    try:
        plan = ct.models.compute_plan.MLComputePlan.load_from_path(model.get_compiled_model_path(), compute_units=units)
        counts: Counter[str] = Counter()
        program = plan.model_structure.program
        if program is None:
            return {"status": "unavailable", "reason": "model has no ML Program structure"}
        for function in program.functions.values():
            for operation in function.block.operations:
                usage = plan.get_compute_device_usage_for_mlprogram_operation(operation)
                device = type(usage.preferred_compute_device).__name__ if usage else "unknown"
                counts[device] += 1
        return {"status": "estimated", "preferred_operation_counts": dict(counts), "observed_dispatch": False}
    except (RuntimeError, ValueError, AttributeError) as error:
        return {"status": "unavailable", "reason": str(error), "observed_dispatch": False}


def run_parity(g: Geometry, weights: dict[str, torch.Tensor], output: Path, units: ct.ComputeUnit) -> dict[str, object]:
    started = time.monotonic()
    prefill = ct.models.MLModel(str(output / "prefill64.mlpackage"), compute_units=units)
    decode = ct.models.MLModel(str(output / "decode1.mlpackage"), compute_units=units)
    load_seconds = time.monotonic() - started
    prefill_state, decode_state = prefill.make_state(), decode.make_state()
    torch_block = ANEBlock(g, weights, dtype=torch.float16).eval()
    x = torch.randn((67, g.hidden), generator=torch.Generator().manual_seed(1901)).half()
    expected = reference_block(x.float(), weights, g).numpy()
    rows: list[dict[str, object]] = []

    def predict(model: ct.models.MLModel, state: MLState, start: int, count: int) -> NDArray[np.float16]:
        mask = causal_mask(start, count, g.context).astype(np.float16)[None, None]
        arrays = {"hidden": x[start:start + count].T[None, :, None, :].numpy(), "position": np.array([start], dtype=np.int32), "mask": mask}
        with torch.no_grad():
            layout = torch_block(*(torch.from_numpy(arrays[name]) for name in ("hidden", "position", "mask")))
        tick = time.monotonic()
        result = model.predict(arrays, state=state)["output"]
        elapsed = time.monotonic() - tick
        validation: dict[str, object] = {"position": start, "count": count, "prediction_seconds": elapsed,
            "reference_output": compare(result[0, :, 0].T, expected[start:start + count]),
            "layout_output": compare(result, layout.numpy())}
        for name in ("k_cache", "v_cache"):
            validation[name] = compare(state.read_state(name), getattr(torch_block, name).numpy(), state=True)
        rows.append(validation)
        return result

    first = predict(prefill, prefill_state, 0, 64)
    # Separate models have separate MLState objects: copy values explicitly, never assume aliasing.
    for name in ("k_cache", "v_cache"):
        decode_state.write_state(name, prefill_state.read_state(name))
    for position in (64, 65, 66):
        predict(decode, decode_state, position, 1)

    # Tokenwise decode from a fresh state must match batch-prefill output and cache contents.
    fresh_state = decode.make_state()
    tokenwise = []
    for position in range(64):
        arrays = {"hidden": x[position:position + 1].T[None, :, None, :].numpy(),
                  "position": np.array([position], dtype=np.int32),
                  "mask": causal_mask(position, 1, g.context).astype(np.float16)[None, None]}
        tokenwise.append(decode.predict(arrays, state=fresh_state)["output"])
    sequential = np.concatenate(tokenwise, axis=-1)
    batch_parity = compare(first, sequential)
    cache_parity = {name: compare(prefill_state.read_state(name), fresh_state.read_state(name), state=True)
                    for name in ("k_cache", "v_cache")}
    # Explicitly zero an already-used state and replay. A fresh request cannot retain past values.
    for name in ("k_cache", "v_cache"):
        prefill_state.write_state(name, np.zeros_like(prefill_state.read_state(name)))
    torch_block.reset()
    replay = predict(prefill, prefill_state, 0, 64)
    reset_parity = compare(first, replay)
    return {"status": "passed", "compute_permissions": units.name, "model_load_seconds": load_seconds,
            "rows": rows, "prefill_vs_64_decode": batch_parity, "prefill_vs_64_decode_cache": cache_parity,
            "state_reset_replay": reset_parity, "placement": compute_plan(decode, units)}


def execute(output: Path, g: Geometry, include_ne: bool) -> int:
    output.mkdir(parents=True, exist_ok=True)
    available = shutil.disk_usage(output).free
    if available < RESERVE_BYTES + ARTIFACT_BUDGET_BYTES:
        raise RuntimeError(f"Storage preflight refused: {available} bytes free; need {RESERVE_BYTES + ARTIFACT_BUDGET_BYTES} including reserve")
    scratch = output / "tmp"
    scratch.mkdir(exist_ok=True)
    tempfile.tempdir = str(scratch.resolve())
    torch.set_num_threads(4)
    started = time.monotonic()
    compute_runs: list[dict[str, object]] = []
    report: dict[str, object] = {"synthetic": True, "cleanup_model": False, "device_measurement": False,
        "geometry": asdict(g), "seed_weights": 39, "seed_inputs": 1901,
        "platform": platform.platform(), "python": sys.version, "torch": torch.__version__, "coremltools": ct.__version__,
        "output_tolerance": {"atol": OUTPUT_ATOL, "rtol": OUTPUT_RTOL},
        "state_tolerance": {"atol": STATE_ATOL, "rtol": STATE_RTOL}, "free_bytes_before": available,
        "compute_runs": compute_runs, "state_transfer": "explicit Python read_state/write_state between separate prefill and decode models"}
    exit_code = 0
    try:
        weights = synthetic_weights(g)
        report["weights_fp16_bytes"] = sum(value.numel() * 2 for value in weights.values())
        report["kv_state_bytes"] = 2 * int(np.prod(g.cache_shape)) * 2
        report["exports"] = {str(count): export_block(g, weights, count, output / name)
                             for count, name in [(1, "decode1.mlpackage"), (64, "prefill64.mlpackage")]}
        runs = [ct.ComputeUnit.CPU_ONLY] + ([ct.ComputeUnit.CPU_AND_NE] if include_ne else [])
        for units in runs:
            result: dict[str, object]
            try:
                result = run_parity(g, weights, output, units)
            except (RuntimeError, ValueError, AssertionError) as error:
                result = {"status": "failed", "compute_permissions": units.name, "error": str(error)}
                exit_code = 1
            compute_runs.append(result)
    except Exception as error:
        report["export_error"] = {"type": type(error).__name__, "message": str(error)}
        exit_code = 1
    report["total_seconds"] = time.monotonic() - started
    report["process_peak_rss_bytes"] = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    report["artifact_bytes"] = sum(f.stat().st_size for f in output.rglob("*") if f.is_file())
    report["free_bytes_after"] = shutil.disk_usage(output).free
    report["status"] = "passed" if exit_code == 0 else "failed"
    (output / "result.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))
    return exit_code
