"""Independent full-prefix oracle checks stateful prefill, decode and request isolation."""
import numpy as np
import pytest
import torch

from ane_conversion.contracts import causal_mask
from ane_conversion.geometry import Geometry, synthetic_weights
from ane_conversion.layout import ANEBlock
from ane_conversion.reference import reference_block


@pytest.fixture
def case() -> tuple[Geometry, dict[str, torch.Tensor], torch.Tensor]:
    g = Geometry(hidden=16, intermediate=32, query_heads=4, kv_heads=2, head_dim=8, context=128)
    x = torch.randn((70, 16), generator=torch.Generator().manual_seed(1901))
    return g, synthetic_weights(g), x


def step(model: ANEBlock, x: torch.Tensor, start: int, g: Geometry) -> torch.Tensor:
    mask = torch.from_numpy(causal_mask(start, len(x), g.context))[None, None]
    return model(x.T[None, :, None, :], torch.tensor([start], dtype=torch.int32), mask)[0, :, 0].T


def test_prefill_64_then_decode_matches_independent_prefix(case: tuple[Geometry, dict[str, torch.Tensor], torch.Tensor]) -> None:
    g, weights, x = case
    model = ANEBlock(g, weights)
    with torch.no_grad():
        prefill = step(model, x[:64], 0, g)
        np.testing.assert_allclose(prefill, reference_block(x[:64], weights, g), atol=1e-5, rtol=1e-5)
        for position in [64, 65, 66]:
            result = step(model, x[position:position + 1], position, g)
            np.testing.assert_allclose(result, reference_block(x[:position + 1], weights, g)[-1:], atol=1e-5, rtol=1e-5)


def test_prefill_matches_tokenwise_decode_and_writes_only_prefix(case: tuple[Geometry, dict[str, torch.Tensor], torch.Tensor]) -> None:
    g, weights, x = case
    prefill, decode = ANEBlock(g, weights), ANEBlock(g, weights)
    with torch.no_grad():
        batched = step(prefill, x[:8], 0, g)
        sequential = torch.cat([step(decode, x[i:i + 1], i, g) for i in range(8)])
    np.testing.assert_allclose(batched, sequential, atol=1e-5, rtol=1e-5)
    assert prefill.k_cache[:, :, :8].abs().sum() > 0
    assert prefill.v_cache[:, :, :8].abs().sum() > 0
    assert prefill.k_cache[:, :, 8:].count_nonzero() == 0
    np.testing.assert_allclose(prefill.k_cache, decode.k_cache, atol=1e-5, rtol=1e-5)


def test_reset_reproduces_fresh_request_after_different_history(case: tuple[Geometry, dict[str, torch.Tensor], torch.Tensor]) -> None:
    g, weights, x = case
    used, fresh = ANEBlock(g, weights), ANEBlock(g, weights)
    with torch.no_grad():
        step(used, x[:64], 0, g)
        assert used.k_cache.count_nonzero() > 0
        used.reset()
        assert used.k_cache.count_nonzero() == 0
        assert used.v_cache.count_nonzero() == 0
        result = step(used, x[64:68], 0, g)
        expected = step(fresh, x[64:68], 0, g)
    np.testing.assert_allclose(result, expected, atol=1e-5, rtol=1e-5)


def test_future_input_does_not_change_earlier_outputs(case: tuple[Geometry, dict[str, torch.Tensor], torch.Tensor]) -> None:
    g, weights, x = case
    changed = x[:8].clone()
    changed[4:] *= 20
    with torch.no_grad():
        first = step(ANEBlock(g, weights), x[:8], 0, g)
        np.testing.assert_allclose(first, reference_block(x[:8], weights, g), atol=1e-5, rtol=1e-5)
        second = step(ANEBlock(g, weights), changed, 0, g)
    np.testing.assert_allclose(first[:4], second[:4], atol=1e-6, rtol=1e-6)
