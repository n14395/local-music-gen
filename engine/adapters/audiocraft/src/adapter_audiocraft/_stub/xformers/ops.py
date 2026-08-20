"""Functional stand-in for xformers.ops on macOS.

audiocraft uses three things from here:
- ``unbind`` — layout-preserving torch.unbind.
- ``LowerTriangularMask`` — causal-mask sentinel.
- ``memory_efficient_attention`` — MAGNeT *requires* this path (its torch
  branch drops the custom restricted-context mask and treats everything as
  causal), so this is a faithful SDPA emulation, not a raiser: xformers layout
  is (batch, seq, heads, dim) with an additive float bias and 1/sqrt(dim)
  scaling — identical semantics to torch's scaled_dot_product_attention after
  a transpose.
"""

import torch
import torch.nn.functional as F


class LowerTriangularMask:
    pass


def unbind(x: torch.Tensor, dim: int = 0):
    return x.unbind(dim)


def memory_efficient_attention(query: torch.Tensor, key: torch.Tensor,
                               value: torch.Tensor, attn_bias=None,
                               p: float = 0.0) -> torch.Tensor:
    q = query.transpose(1, 2)  # (B, T, H, D) -> (B, H, T, D)
    k = key.transpose(1, 2)
    v = value.transpose(1, 2)
    if isinstance(attn_bias, LowerTriangularMask):
        out = F.scaled_dot_product_attention(q, k, v, dropout_p=p,
                                             is_causal=True)
    else:
        out = F.scaled_dot_product_attention(q, k, v, attn_mask=attn_bias,
                                             dropout_p=p)
    return out.transpose(1, 2)
