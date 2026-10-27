"""Independent float32, full-sequence matmul oracle; no export/cache implementation reuse."""
import torch

from .geometry import Geometry


def reference_block(x: torch.Tensor, w: dict[str, torch.Tensor], g: Geometry) -> torch.Tensor:
    """Return all causal decoder outputs for a complete prefix shaped [sequence, hidden]."""
    def norm(value: torch.Tensor, weight: torch.Tensor) -> torch.Tensor:
        return value * torch.rsqrt(value.square().mean(-1, keepdim=True) + g.epsilon) * weight

    count = x.shape[0]
    hidden = norm(x.float(), w["input_norm"])
    q = norm((hidden @ w["q"].T).reshape(count, g.query_heads, g.head_dim), w["q_norm"])
    k = norm((hidden @ w["k"].T).reshape(count, g.kv_heads, g.head_dim), w["k_norm"])
    v = (hidden @ w["v"].T).reshape(count, g.kv_heads, g.head_dim)
    frequency = g.rope_theta ** (-torch.arange(0, g.head_dim, 2).float() / g.head_dim)
    angles = torch.arange(count).float()[:, None] * frequency[None, :]
    cos = torch.cat([angles.cos(), angles.cos()], dim=-1)[:, None, :]
    sin = torch.cat([angles.sin(), angles.sin()], dim=-1)[:, None, :]
    def rotate(value: torch.Tensor) -> torch.Tensor:
        first, second = value.chunk(2, dim=-1)
        return value * cos + torch.cat([-second, first], dim=-1) * sin
    q = rotate(q).transpose(0, 1)
    k = rotate(k).repeat_interleave(g.query_heads // g.kv_heads, dim=1).transpose(0, 1)
    v = v.repeat_interleave(g.query_heads // g.kv_heads, dim=1).transpose(0, 1)
    scores = q @ k.transpose(-1, -2) / g.head_dim ** 0.5
    disallowed = torch.triu(torch.ones(count, count, dtype=torch.bool), diagonal=1)
    scores = scores.masked_fill(disallowed, -10000.0)
    attended = (scores.softmax(-1) @ v).transpose(0, 1).reshape(count, -1)
    residual = x.float() + attended @ w["o"].T
    hidden = norm(residual, w["post_norm"])
    return residual + (torch.nn.functional.silu(hidden @ w["gate"].T) * (hidden @ w["up"].T)) @ w["down"].T
