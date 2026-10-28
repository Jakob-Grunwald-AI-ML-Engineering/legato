"""CLI for the synthetic single-layer experiment. No model/checkpoint downloads."""
import argparse
from pathlib import Path

from ane_conversion.experiment import execute
from ane_conversion.geometry import Geometry


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=Path("artifacts/qwen3-single-layer"))
    parser.add_argument("--geometry", choices=["qwen3-0.6b", "tiny"], default="qwen3-0.6b")
    parser.add_argument("--include-ne", action="store_true", help="Also request CPU_AND_NE; does not prove ANE dispatch")
    args = parser.parse_args()
    geometry = Geometry() if args.geometry == "qwen3-0.6b" else Geometry(hidden=16, intermediate=32, query_heads=4, kv_heads=2, head_dim=8, context=128)
    return execute(args.output, geometry, args.include_ne)


if __name__ == "__main__":
    raise SystemExit(main())
