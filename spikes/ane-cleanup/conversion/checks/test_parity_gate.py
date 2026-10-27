"""Numeric and top-token requirements are fixed before running the trained weights."""
import numpy as np
import pytest

from ane_conversion.parity_gate import assess_logits


def test_accepts_numerically_close_logits_with_identical_top_token() -> None:
    result = assess_logits(np.array([1.03, 0.1], dtype=np.float32), np.array([1.0, 0.0], dtype=np.float32))
    assert result["passed"] is True


def test_rejects_top_token_change_even_when_all_logits_are_within_tolerance() -> None:
    result = assess_logits(np.array([0.99, 1.01], dtype=np.float32), np.array([1.01, 0.99], dtype=np.float32))
    assert result["passed"] is False


def test_rejects_excess_logit_error_even_when_top_token_matches() -> None:
    result = assess_logits(np.array([1.5, 0.0], dtype=np.float32), np.array([1.0, 0.0], dtype=np.float32))
    assert result["passed"] is False


@pytest.mark.parametrize("value", [float("nan"), float("inf")])
def test_rejects_nonfinite_logits(value: float) -> None:
    result = assess_logits(np.array([value, 0.0], dtype=np.float32), np.array([1.0, 0.0], dtype=np.float32))
    assert result["passed"] is False


def test_quantized_model_requires_explicit_strict_gate_opt_in() -> None:
    from ane_conversion.parity_gate import quantization_label

    with pytest.raises(ValueError, match="explicit strict quantized gate"):
        quantization_label(6, 6)


def test_strict_quantized_opt_in_reports_actual_precision_without_relaxing_gate() -> None:
    from ane_conversion.parity_gate import quantization_label

    assert quantization_label(6, 6, allow_quantized=True) == "ffn=lut6;lm_head=lut6"
    result = assess_logits(np.array([1.5, 0.0], dtype=np.float32), np.array([1.0, 0.0], dtype=np.float32))
    assert result["passed"] is False
    assert result["atol"] == 0.10
    assert result["rtol"] == 0.02


def test_unquantized_artifact_keeps_existing_default_gate() -> None:
    from ane_conversion.parity_gate import quantization_label

    assert quantization_label("none", None) == "fp16"
