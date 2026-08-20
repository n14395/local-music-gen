"""Import stub for xformers on macOS.

audiocraft's transformer module does `from xformers import ops` at import time,
but with the default 'torch' efficient-attention backend none of its kernels
are ever invoked. xformers publishes no macOS wheels, so the real package
cannot be installed; the adapter puts this stub on sys.path instead.
"""

from . import ops  # noqa: F401
