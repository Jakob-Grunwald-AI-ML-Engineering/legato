"""Single decoder block using 1x1 convolutions, per-head attention and registered KV state."""
# PyTorch decorators/Module initialization have incomplete upstream annotations.
# pyright: reportUnknownMemberType=false, reportUntypedFunctionDecorator=false
import torch
import torch.nn.functional as functional

from .geometry import Geometry


class ANEBlock(torch.nn.Module):
    k_cache: torch.Tensor
    v_cache: torch.Tensor
    rotary_cos: torch.Tensor
    rotary_sin: torch.Tensor

    def __init__(self, geometry: Geometry, weights: dict[str, torch.Tensor], dtype: torch.dtype = torch.float32) -> None:
        super().__init__()
        self.geometry = geometry
        self.weights = torch.nn.ParameterDict({name: torch.nn.Parameter(value.to(dtype), requires_grad=False) for name, value in weights.items()})
        self.register_buffer("k_cache", torch.zeros(geometry.cache_shape, dtype=dtype))
        self.register_buffer("v_cache", torch.zeros(geometry.cache_shape, dtype=dtype))
        inverse = 1.0 / geometry.rope_theta ** (torch.arange(0, geometry.head_dim, 2).float() / geometry.head_dim)
        angles = torch.arange(geometry.context).float()[:, None] * inverse[None, :]
        self.register_buffer("rotary_cos", torch.cat((angles.cos(), angles.cos()), -1).to(dtype))
        self.register_buffer("rotary_sin", torch.cat((angles.sin(), angles.sin()), -1).to(dtype))

    def _conv(self, x: torch.Tensor, name: str) -> torch.Tensor:
        return functional.conv2d(x, self.weights[name][:, :, None, None])

    def _norm_channels(self, x: torch.Tensor, name: str) -> torch.Tensor:
        return x * torch.rsqrt(x.square().mean(1, keepdim=True) + self.geometry.epsilon) * self.weights[name][None, :, None, None]

    def _head(self, x: torch.Tensor, count: int) -> torch.Tensor:
        return x.reshape(1, count, self.geometry.head_dim, x.shape[-1]).permute(0, 1, 3, 2)

    def _norm_head(self, x: torch.Tensor, name: str) -> torch.Tensor:
        return x * torch.rsqrt(x.square().mean(-1, keepdim=True) + self.geometry.epsilon) * self.weights[name][None, None, None, :]

    def _rotary(self, x: torch.Tensor, positions: torch.Tensor) -> torch.Tensor:
        half = self.geometry.head_dim // 2
        rotated = torch.cat((-x[:, :, :, half:], x[:, :, :, :half]), -1)
        cos = self.rotary_cos.index_select(0, positions)[None, None, :, :]
        sin = self.rotary_sin.index_select(0, positions)[None, None, :, :]
        return x * cos + rotated * sin

    def forward(self, x: torch.Tensor, position: torch.Tensor, mask: torch.Tensor) -> torch.Tensor:
        g = self.geometry
        count = x.shape[-1]
        positions = position[0] + torch.arange(count, device=x.device, dtype=torch.int32)
        hidden = self._norm_channels(x, "input_norm")
        query = self._rotary(self._norm_head(self._head(self._conv(hidden, "q"), g.query_heads), "q_norm"), positions)
        key = self._rotary(self._norm_head(self._head(self._conv(hidden, "k"), g.kv_heads), "k_norm"), positions)
        value = self._head(self._conv(hidden, "v"), g.kv_heads)
        # Dynamic slice assignment lowered incorrectly in the measured Core ML export:
        # nonzero decode positions overwrote slot zero. Use an explicit dynamic write map.
        slots = torch.arange(g.context, device=x.device, dtype=torch.int32)
        write_map = (positions[:, None] == slots[None, :]).to(x.dtype)
        occupied = write_map.sum(dim=0)[None, None, :, None]
        self.k_cache[:, :, :, :] = self.k_cache * (1 - occupied) + torch.matmul(key.transpose(-1, -2), write_map).transpose(-1, -2)
        self.v_cache[:, :, :, :] = self.v_cache * (1 - occupied) + torch.matmul(value.transpose(-1, -2), write_map).transpose(-1, -2)
        attended: list[torch.Tensor] = []
        for head in range(g.query_heads):
            kv_head = head // (g.query_heads // g.kv_heads)
            scores = torch.matmul(query[:, head:head + 1], self.k_cache[:, kv_head:kv_head + 1].transpose(-1, -2)) * (g.head_dim ** -0.5)
            probabilities = torch.softmax(scores + mask, dim=-1)
            attended.append(torch.matmul(probabilities, self.v_cache[:, kv_head:kv_head + 1]))
        attention = torch.cat(attended, dim=1).permute(0, 1, 3, 2).reshape(1, g.query_heads * g.head_dim, 1, count)
        residual = x + self._conv(attention, "o")
        hidden = self._norm_channels(residual, "post_norm")
        return residual + self._conv(functional.silu(self._conv(hidden, "gate")) * self._conv(hidden, "up"), "down")

    @torch.no_grad()
    def reset(self) -> None:
        self.k_cache.zero_()
        self.v_cache.zero_()
