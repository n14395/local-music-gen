"""A download that never touches the network."""

from __future__ import annotations


class FakeResponse:
    """`urlopen`'s context manager, over a list of blocks.

    `headers` is a plain dict because that is all `_fetch` asks of it:
    `.get("Content-Length")`.
    """

    def __init__(self, blocks: list[bytes], *,
                 content_length: int | None = None) -> None:
        self.blocks = list(blocks)
        self.headers = {}
        if content_length is not None:
            self.headers["Content-Length"] = str(content_length)
        self.opened = 0

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False

    def read(self, _n: int = -1) -> bytes:
        return self.blocks.pop(0) if self.blocks else b""


def megabytes(n: int) -> list[bytes]:
    return [b"\0" * (1 << 20) for _ in range(n)]


class Opener:
    """A stand-in for `urllib.request.urlopen` that records its URLs."""

    def __init__(self, *responses: FakeResponse) -> None:
        self.responses = list(responses)
        self.urls: list[str] = []

    def __call__(self, url, *a, **kw):
        self.urls.append(url)
        return self.responses.pop(0)


class Progress:
    """A ProgressCb that can raise, the way a cancelled job's does."""

    def __init__(self, raise_at: int | None = None,
                 exc: type[BaseException] | None = None) -> None:
        self.messages: list[str] = []
        self.raise_at = raise_at
        self.exc = exc

    def __call__(self, fraction, message, *, phase=None, step=None,
                 steps=None) -> None:
        self.messages.append(message)
        if self.raise_at is not None and len(self.messages) >= self.raise_at:
            from engine_protocol.adapter import CancelledError
            raise (self.exc or CancelledError)()
