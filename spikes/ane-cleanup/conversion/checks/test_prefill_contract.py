"""The source converter deliberately omits final norm from prefill output."""
import numpy as np
from numpy.typing import NDArray

from ane_conversion.prefill_contract import validate_prefill_then_infer


def test_ignores_unnormalized_prefill_output_and_checks_subsequent_infer_logits() -> None:
    events: list[str | int] = []
    prefix_length = 0
    expected = np.zeros((67, 2), dtype=np.float32)
    expected[64:67] = [[64.5, -1.0], [65.5, -1.0], [66.5, -1.0]]

    def prefill() -> NDArray[np.float32]:
        nonlocal prefix_length
        events.append("prefill")
        prefix_length = 64
        return np.array([-999.0, 1234.0], dtype=np.float32)

    def infer(position: int) -> NDArray[np.float32]:
        nonlocal prefix_length
        assert position == prefix_length
        events.append(position)
        prefix_length += 1
        return np.array([position + 0.5, -1.0], dtype=np.float32)

    rows = validate_prefill_then_infer(prefill, infer, expected, (64, 65, 66))
    assert all(row["passed"] is True for row in rows)
    assert len(rows) == 3
    assert events == ["prefill", 64, 65, 66]


def test_rejects_bad_infer_logits_instead_of_treating_prefill_as_success() -> None:
    expected = np.zeros((65, 2), dtype=np.float32)
    expected[63:65] = [[1.0, 0.0], [1.0, 0.0]]
    rows = validate_prefill_then_infer(lambda: np.array([1.0, 0.0], dtype=np.float32), lambda position: np.array([0.0, 1.0], dtype=np.float32), expected, (64,))
    assert rows[0]["passed"] is False
