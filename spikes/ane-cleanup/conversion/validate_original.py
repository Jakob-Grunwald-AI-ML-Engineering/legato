"""Compare original HF weights with unquantized ANEMLL PyTorch inference; not Core ML proof."""
# Dynamically loaded ANEMLL and HF model classes are untyped third-party boundaries.
# pyright: reportUnknownVariableType=false, reportUnknownMemberType=false, reportUnknownArgumentType=false
import argparse
import hashlib
import json
import resource
import sys
import time
from pathlib import Path

import numpy as np
import torch
from transformers.models.auto.modeling_auto import AutoModelForCausalLM
from transformers.models.auto.tokenization_auto import AutoTokenizer

from ane_conversion.contracts import causal_mask
from ane_conversion.parity_gate import LOGIT_ATOL, LOGIT_RTOL, assess_logits


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--upstream", type=Path, required=True)
    parser.add_argument("--source", type=Path, default=Path("artifacts/qwen3-06b-full/source"))
    parser.add_argument("--output", type=Path, default=Path("artifacts/qwen3-06b-full/original-parity.json"))
    args = parser.parse_args()
    torch.set_num_threads(2)
    sys.dont_write_bytecode = True
    sys.path.insert(0, str(args.upstream.resolve()))
    from anemll.models.qwen_model import (  # pyright: ignore[reportMissingImports] - pinned checkout is supplied at runtime
        QwenConfig,
        QwenForCausalLM,
    )

    fixture_path = Path(__file__).parent / "checks/fixtures/prefix-parity.json"
    fixtures = json.loads(fixture_path.read_text())
    rows: list[dict[str, object]] = []
    report: dict[str, object] = {"status": "running", "coreml_lowering_validated": False, "quantized": False,
        "fixture_scope": "newly authored spike regression prefixes; not a sealed quality holdout", "fixture_sha256": hashlib.sha256(fixture_path.read_bytes()).hexdigest(),
        "source_revision": "c1899de289a04d12100db370d81485cdf75e47ca", "atol": LOGIT_ATOL, "rtol": LOGIT_RTOL,
        "require_prefix_top1_match": True, "reference_dtype": "float32", "anemll_dtype": "float16", "rows": rows}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + "\n")
    tick = time.monotonic()
    exit_code = 0
    try:
        tokenizer = AutoTokenizer.from_pretrained(args.source, local_files_only=True)
        original = AutoModelForCausalLM.from_pretrained(args.source, local_files_only=True, torch_dtype=torch.float32, attn_implementation="eager").eval()
        config = QwenConfig.from_json(str(args.source / "config.json"))
        config.context_length = config.state_length = 2048
        adapted = QwenForCausalLM(config, enable_coreml=False).eval()
        if not adapted.load_pretrained_weights(str(args.source)):
            raise RuntimeError("ANEMLL reported incomplete original-weight load")
        for fixture in fixtures:
            tokens = tokenizer.encode(fixture["text"], add_special_tokens=False)
            if not 1 <= len(tokens) <= 128:
                raise ValueError("prefix length outside the declared 1..128 token range; no truncation allowed")
            for name, buffer in adapted.named_buffers():
                if "kv_cache" in name:
                    buffer.zero_()
            selected = {1, min(8, len(tokens)), len(tokens)}
            with torch.no_grad():
                expected = original(torch.tensor([tokens], dtype=torch.long), use_cache=False).logits[0].float().numpy()
                for position, token in enumerate(tokens):
                    outputs = adapted(input_ids=torch.tensor([[token]], dtype=torch.int32),
                        update_mask=torch.zeros((1, 1, 2048, 1), dtype=torch.float16),
                        position_ids=torch.tensor([position], dtype=torch.int32),
                        causal_mask=torch.from_numpy(causal_mask(position, 1, 2048).astype(np.float16))[None, None],
                        current_pos=torch.tensor([position], dtype=torch.int32), IN_PREFILL=False)
                    if position + 1 not in selected:
                        continue
                    logits = torch.cat(outputs, dim=-1) if isinstance(outputs, tuple) else outputs
                    result = assess_logits(logits[0, -1].float().numpy(), expected[position])
                    result.update({"fixture_id": fixture["id"], "prefix_tokens": position + 1})
                    rows.append(result)
                    if not result["passed"]:
                        exit_code = 1
            args.output.write_text(json.dumps(report, indent=2) + "\n")
        report["status"] = "passed" if exit_code == 0 else "failed"
    except Exception as error:
        report.update({"status": "failed", "error_type": type(error).__name__, "error": str(error)})
        exit_code = 1
    report.update({"seconds": time.monotonic() - tick, "process_peak_rss_bytes": resource.getrusage(resource.RUSAGE_SELF).ru_maxrss})
    args.output.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))
    return exit_code


if __name__ == "__main__":
    raise SystemExit(main())
