"""Cache and causal-window invariants shared by validation and host input construction."""
import numpy as np
from numpy.typing import NDArray


def validate_window(start: int, count: int, context: int) -> None:
    if start < 0 or count <= 0 or start + count > context:
        raise ValueError("window must be nonempty and inside context")


def causal_mask(start: int, count: int, context: int) -> NDArray[np.float32]:
    validate_window(start, count, context)
    keys = np.arange(context)[None, :]
    queries = (start + np.arange(count))[:, None]
    return np.where(keys <= queries, 0.0, -10000.0).astype(np.float32)


def update_cache(cache: NDArray[np.float32], values: NDArray[np.float32], start: int) -> NDArray[np.float32]:
    if cache.ndim != 4 or values.ndim != 4:
        raise ValueError("cache and values must have rank four")
    validate_window(start, values.shape[2], cache.shape[2])
    if cache.shape[:2] != values.shape[:2] or cache.shape[3] != values.shape[3]:
        raise ValueError("cache and values must have matching head dimensions")
    result = cache.copy()
    result[:, :, start:start + values.shape[2], :] = values
    return result


def reset_cache(cache: NDArray[np.float32]) -> NDArray[np.float32]:
    return np.zeros_like(cache)
