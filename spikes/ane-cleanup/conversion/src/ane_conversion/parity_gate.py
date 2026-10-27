"""Fixed original-weight prefix-logit gate; quantized diagnostics require explicit opt-in."""
import numpy as np
from numpy.typing import NDArray

LOGIT_ATOL = 0.10
LOGIT_RTOL = 0.02


def assess_logits(actual: NDArray[np.float32], expected: NDArray[np.float32]) -> dict[str, object]:
    if actual.shape != expected.shape or actual.size == 0:
        return {"passed": False, "reason": "empty or mismatched logit shape"}
    finite = bool(np.isfinite(actual).all() and np.isfinite(expected).all())
    if not finite:
        return {"passed": False, "reason": "nonfinite logits"}
    difference = np.abs(actual - expected)
    exceeded = difference > LOGIT_ATOL + LOGIT_RTOL * np.abs(expected)
    actual_top, expected_top = int(np.argmax(actual)), int(np.argmax(expected))
    return {"passed": bool(not exceeded.any() and actual_top == expected_top),
            "max_absolute_error": float(difference.max()), "mean_absolute_error": float(difference.mean()),
            "elements_outside_tolerance": int(exceeded.sum()), "elements": int(actual.size),
            "actual_top1": actual_top, "expected_top1": expected_top, "top1_matches": actual_top == expected_top,
            "atol": LOGIT_ATOL, "rtol": LOGIT_RTOL}


def quantization_label(lut_ffn: object, lut_lmhead: object, *, allow_quantized: bool = False) -> str:
    """Keep the FP16 default guard; an explicit quantized run retains the same numeric gate."""
    unquantized = (None, "none", -1)
    if lut_ffn in unquantized and lut_lmhead in unquantized:
        return "fp16"
    if not allow_quantized:
        raise ValueError("Quantized weights require an explicit strict quantized gate opt-in")
    ffn = "fp16" if lut_ffn in unquantized else f"lut{lut_ffn}"
    head = "fp16" if lut_lmhead in unquantized else f"lut{lut_lmhead}"
    return f"ffn={ffn};lm_head={head}"
