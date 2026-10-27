"""Pinned Qwen3-0.6B dimensions, deterministic synthetic weights, and fixed error limits."""
from dataclasses import dataclass

import torch

OUTPUT_ATOL = 0.02
OUTPUT_RTOL = 0.02
STATE_ATOL = 0.005
STATE_RTOL = 0.02


@dataclass(frozen=True)
class Geometry:
    hidden: int = 1024
    intermediate: int = 3072
    query_heads: int = 16
    kv_heads: int = 8
    head_dim: int = 128
    context: int = 2048
    rope_theta: float = 1_000_000.0
    epsilon: float = 1e-6

    @property
    def cache_shape(self) -> tuple[int, int, int, int]:
        return (1, self.kv_heads, self.context, self.head_dim)


def synthetic_weights(g: Geometry, seed: int = 39) -> dict[str, torch.Tensor]:
    generator = torch.Generator(device="cpu").manual_seed(seed)
    shapes = {"q": (g.query_heads * g.head_dim, g.hidden),
              "k": (g.kv_heads * g.head_dim, g.hidden),
              "v": (g.kv_heads * g.head_dim, g.hidden),
              "o": (g.hidden, g.query_heads * g.head_dim),
              "gate": (g.intermediate, g.hidden),
              "up": (g.intermediate, g.hidden),
              "down": (g.hidden, g.intermediate)}
    weights = {name: torch.randn(shape, generator=generator) * 0.02 for name, shape in shapes.items()}
    for name, size in [("input_norm", g.hidden), ("post_norm", g.hidden),
                       ("q_norm", g.head_dim), ("k_norm", g.head_dim)]:
        weights[name] = torch.ones(size) + torch.randn(size, generator=generator) * 0.01
    return weights
