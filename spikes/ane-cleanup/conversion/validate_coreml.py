"""Check compiled inference/prefill against HF logits; quantized strict gate is explicit opt-in."""
# Scientific model wrappers have incomplete upstream annotations; keep unknowns at this boundary.
# pyright: reportMissingTypeStubs=false, reportUnknownMemberType=false, reportUnknownVariableType=false, reportUnknownArgumentType=false
import argparse
import json
import os
import resource
import time
from pathlib import Path

import coremltools as ct
import numpy as np
import torch
import yaml
from coremltools.models.model import MLState
from numpy.typing import NDArray
from transformers.models.auto.modeling_auto import AutoModelForCausalLM
from transformers.models.auto.tokenization_auto import AutoTokenizer

from ane_conversion.contracts import causal_mask
from ane_conversion.parity_gate import LOGIT_ATOL, LOGIT_RTOL, assess_logits, quantization_label
from ane_conversion.prefill_contract import validate_prefill_then_infer
from ane_conversion.provenance import validation_provenance

type Model = ct.models.MLModel | ct.models.CompiledMLModel


def load(path: Path, units: ct.ComputeUnit, function: str | None = None) -> Model:
    if path.suffix == ".mlmodelc":
        return ct.models.CompiledMLModel(str(path), compute_units=units, function_name=function)
    return ct.models.MLModel(str(path), compute_units=units, function_name=function)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", type=Path, default=Path("artifacts/qwen3-06b-fp16/converted"))
    parser.add_argument("--source", type=Path, default=Path("artifacts/qwen3-06b-full/source"))
    parser.add_argument("--prefill-batches", nargs="+", type=int, default=[1, 2])
    parser.add_argument("--skip-prefixes", action="store_true", help="Run only controlled prefill transitions")
    parser.add_argument("--compute", choices=["cpu", "cpu-and-ne"], default="cpu")
    parser.add_argument("--strict-quantized-gate", action="store_true", help="Allow quantized artifact with unchanged numeric and top1 requirements; not a relaxed quantization-quality gate")
    parser.add_argument("--output", type=Path, default=Path("artifacts/qwen3-06b-fp16/coreml-parity-cpu.json"))
    args = parser.parse_args()
    torch.set_num_threads(2)
    units = ct.ComputeUnit.CPU_ONLY if args.compute == "cpu" else ct.ComputeUnit.CPU_AND_NE
    rows: list[dict[str, object]] = []
    report: dict[str, object] = {"status": "running", "compute_permissions": units.name, "device_measurement": False,
        "observed_ane_dispatch": False, "quantization": "pending_metadata", "atol": LOGIT_ATOL, "rtol": LOGIT_RTOL,
        "require_prefix_top1_match": True, "state_ownership": "one shared global MLState across chunks/functions, matching pinned Swift/Python runtime", "runner_pid": os.getpid(), "phase": "loading", "rows": rows}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + "\n")
    tick, exit_code = time.monotonic(), 0
    try:
        params = yaml.safe_load((args.model / "meta.yaml").read_text())["model_info"]["parameters"]
        fixture_path = Path(__file__).parent / "checks/fixtures/prefix-parity.json"
        report["input_provenance"] = validation_provenance(args.model, args.source, params, fixture_path,
            {"compute": args.compute, "prefill_batches": args.prefill_batches, "skip_prefixes": args.skip_prefixes,
             "strict_quantized_gate": args.strict_quantized_gate})
        report["phase"] = "inputs_hashed_before_inference"
        args.output.write_text(json.dumps(report, indent=2) + "\n")
        report["quantization"] = quantization_label(params.get("lut_ffn"), params.get("lut_lmhead"), allow_quantized=args.strict_quantized_gate)
        report["strict_quantized_gate"] = args.strict_quantized_gate
        report["model_quantization_parameters"] = {name: params.get(name) for name in ("lut_embeddings", "lut_ffn", "lut_ffn_per_channel", "lut_lmhead", "lut_lmhead_per_channel")}
        context, chunks = int(params["context_length"]), int(params["num_chunks"])
        tokenizer = AutoTokenizer.from_pretrained(args.source, local_files_only=True)
        original = AutoModelForCausalLM.from_pretrained(args.source, local_files_only=True, torch_dtype=torch.float32, attn_implementation="eager").eval()
        embeddings = load(args.model / params["embeddings"], units)
        head = load(args.model / params["lm_head"], units)
        ffn_base = params["ffn"]
        infer = [load(args.model / ffn_base.replace("01of", f"{number:02d}of"), units, "infer") for number in range(1, chunks + 1)]
        prefill = [load(args.model / ffn_base.replace("01of", f"{number:02d}of"), units, "prefill") for number in range(1, chunks + 1)]
        report["loaded_compiled_artifacts"] = all((args.model / params[name]).suffix == ".mlmodelc" for name in ("embeddings", "lm_head", "ffn"))

        def forward(tokens: list[int], start: int, models: list[Model], states: list[MLState], produce_logits: bool = True) -> NDArray[np.float32] | None:
            hidden = embeddings.predict({"input_ids": np.array([tokens], dtype=np.int32)})["hidden_states"]
            inputs = {"hidden_states": hidden, "position_ids": np.arange(start, start + len(tokens), dtype=np.int32),
                      "causal_mask": causal_mask(start, len(tokens), context).astype(np.float16)[None, None],
                      "current_pos": np.array([start], dtype=np.int32)}
            for model, state in zip(models, states, strict=True):
                inputs["hidden_states"] = hidden
                hidden = model.predict(inputs, state=state)["output_hidden_states"]
            if not produce_logits:
                return None
            logits = head.predict({"hidden_states": hidden[:, -1:, :].astype(np.float16)})
            return np.concatenate([logits[f"logits{number}"] for number in range(1, 17)], axis=-1).reshape(-1).astype(np.float32)

        fixtures = json.loads(fixture_path.read_text())
        for fixture in ([] if args.skip_prefixes else fixtures):
            tokens = tokenizer.encode(fixture["text"], add_special_tokens=False)
            shared_state = prefill[0].make_state()
            states = [shared_state] * chunks
            report["phase"] = f"sequential_infer:{fixture["id"]}"
            args.output.write_text(json.dumps(report, indent=2) + "\n")
            with torch.no_grad():
                expected = original(torch.tensor([tokens], dtype=torch.long), use_cache=False).logits[0].float().numpy()
            for position, token in enumerate(tokens):
                actual = forward([token], position, infer, states)
                assert actual is not None
                if position + 1 in {1, 8, len(tokens)}:
                    result = assess_logits(actual, expected[position])
                    result.update({"fixture_id": fixture["id"], "prefix_tokens": position + 1, "path": "sequential_infer"})
                    rows.append(result)
                    if not result["passed"]:
                        exit_code = 1
            args.output.write_text(json.dumps(report, indent=2) + "\n")

        # Controlled mathematical microfixtures; no cleanup prompt/examples are trimmed.
        seed_tokens = tokenizer.encode("The blue ferry leaves after lunch. Die Notiz bleibt unverändert. ", add_special_tokens=False)
        for batches in args.prefill_batches:
            prefill_count = int(batches) * 64
            if not 1 <= int(batches) or prefill_count + 3 > context:
                raise ValueError("prefill batches exceed context reserve")
            tokens = (seed_tokens * ((prefill_count + 3) // len(seed_tokens) + 1))[:prefill_count + 3]
            with torch.no_grad():
                expected = original(torch.tensor([tokens], dtype=torch.long), use_cache=False).logits[0].float().numpy()
            shared_state = prefill[0].make_state()
            prefill_states = [shared_state] * chunks
            def prefill_operation() -> object:
                report["phase"] = f"batch_prefill:{prefill_count}"
                args.output.write_text(json.dumps(report, indent=2) + "\n")
                # Pinned converter omits final norm here. Only state is useful; never compare head(prefill).
                windows: list[list[int]] = []
                for start in range(0, prefill_count, 64):
                    forward(tokens[start:start + 64], start, prefill, prefill_states, produce_logits=False)
                    windows.append([start, 64])
                report["last_prefill_windows"] = windows
                return None

            def infer_operation(position: int) -> NDArray[np.float32]:
                report["phase"] = f"decode_after_prefill:{position}"
                args.output.write_text(json.dumps(report, indent=2) + "\n")
                actual = forward([tokens[position]], position, infer, prefill_states)
                assert actual is not None
                return actual

            transition_rows = validate_prefill_then_infer(prefill_operation, infer_operation, expected, (prefill_count, prefill_count + 1, prefill_count + 2))
            for result in transition_rows:
                result.update({"fixture_id": f"controlled{prefill_count}-token-prefill", "path": "decode_after_prefill"})
                rows.append(result)
                if not result["passed"]:
                    exit_code = 1
        report["status"] = "passed" if exit_code == 0 else "failed"
        report["phase"] = "finished"
    except Exception as error:
        report.update({"status": "failed", "error_type": type(error).__name__, "error": str(error)})
        exit_code = 1
    report.update({"seconds": time.monotonic() - tick, "process_peak_rss_bytes": resource.getrusage(resource.RUSAGE_SELF).ru_maxrss})
    args.output.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))
    return exit_code


if __name__ == "__main__":
    raise SystemExit(main())
