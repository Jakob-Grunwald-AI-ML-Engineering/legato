"""Validate only infer logits after prefill; the prefill output is not normalized."""
from collections.abc import Callable

import numpy as np
from numpy.typing import NDArray

from .parity_gate import assess_logits


def validate_prefill_then_infer(prefill: Callable[[], object], infer: Callable[[int], NDArray[np.float32]], expected: NDArray[np.float32], positions: tuple[int, ...]) -> list[dict[str, object]]:
    prefill()
    rows: list[dict[str, object]] = []
    for position in positions:
        row = assess_logits(infer(position), expected[position])
        row["prefix_tokens"] = position + 1
        rows.append(row)
    return rows
