"""Contract expectations precede implementation; literal boundaries are intentional."""
import numpy as np
import pytest

from ane_conversion.contracts import causal_mask, reset_cache, update_cache


def test_mask_excludes_future_and_unfilled_positions() -> None:
    mask = causal_mask(start=2, count=2, context=6)
    np.testing.assert_array_equal(mask, [[0, 0, 0, -10000, -10000, -10000], [0, 0, 0, 0, -10000, -10000]])


def test_cache_write_preserves_prefix_and_unwritten_tail_without_mutation() -> None:
    original = np.array([[[[7.0], [8.0], [0.0], [0.0], [9.0]]]], dtype=np.float32)
    values = np.array([[[[3.0], [4.0]]]], dtype=np.float32)
    result = update_cache(original, values, start=2)
    np.testing.assert_array_equal(result, [[[[7.0], [8.0], [3.0], [4.0], [9.0]]]])
    np.testing.assert_array_equal(original, [[[[7.0], [8.0], [0.0], [0.0], [9.0]]]])


def test_reset_removes_previous_request_state() -> None:
    original = np.full((1, 2, 6, 3), 7, dtype=np.float32)
    result = reset_cache(original)
    np.testing.assert_array_equal(result, np.zeros((1, 2, 6, 3)))
    assert original.sum() == 252


@pytest.mark.parametrize("start,count", [(-1, 1), (0, 0), (5, 2), (6, 1)])
def test_mask_rejects_invalid_or_overflowing_window(start: int, count: int) -> None:
    with pytest.raises(ValueError, match="window"):
        causal_mask(start=start, count=count, context=6)


def test_prefill_and_decode_cache_writes_have_identical_order() -> None:
    cache = np.zeros((1, 1, 6, 1), dtype=np.float32)
    batch = np.array([[[[2.0], [5.0], [8.0]]]], dtype=np.float32)
    prefill = update_cache(cache, batch, start=1)
    decoded = cache
    for position, value in enumerate([2.0, 5.0, 8.0], start=1):
        decoded = update_cache(decoded, np.array([[[[value]]]], dtype=np.float32), position)
    np.testing.assert_array_equal(prefill, [[[[0.0], [2.0], [5.0], [8.0], [0.0], [0.0]]]])
    np.testing.assert_array_equal(prefill, decoded)


def test_cache_write_rejects_overflow() -> None:
    with pytest.raises(ValueError, match="window"):
        update_cache(np.zeros((1, 1, 3, 1), dtype=np.float32), np.ones((1, 1, 2, 1), dtype=np.float32), 2)
