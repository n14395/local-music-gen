"""A urlopen stand-in: blocks of bytes, never a socket."""

from __future__ import annotations


class FakeResponse:
    def __init__(self, blocks, content_length: int | None = None) -> None:
        self.blocks = list(blocks)
        self.headers = {}
        if content_length is not None:
            self.headers["Content-Length"] = str(content_length)

    def __enter__(self) -> "FakeResponse":
        return self

    def __exit__(self, *exc) -> bool:
        return False

    def read(self, _size: int) -> bytes:
        return self.blocks.pop(0) if self.blocks else b""


MB = b"\0" * (1 << 20)
