"""Real Core ML regression for dynamic decode position/state updates (Mac only)."""
from pathlib import Path

import coremltools as ct

from ane_conversion.experiment import export_block, run_parity
from ane_conversion.geometry import Geometry, synthetic_weights


def test_exported_prefill_decode_reset_preserve_positions(tmp_path: Path) -> None:
    geometry = Geometry(hidden=16, intermediate=32, query_heads=4, kv_heads=2, head_dim=8, context=128)
    weights = synthetic_weights(geometry)
    export_block(geometry, weights, 1, tmp_path / "decode1.mlpackage")
    export_block(geometry, weights, 64, tmp_path / "prefill64.mlpackage")
    result = run_parity(geometry, weights, tmp_path, ct.ComputeUnit.CPU_ONLY)
    assert result["status"] == "passed"
