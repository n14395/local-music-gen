"""MLX speed backend for mono MusicGen models (vendored from mlx-examples).

Import lazily: this package pulls in mlx, which only exists on Apple Silicon.
"""

from .musicgen import MusicGen

__all__ = ["MusicGen"]
