"""The contract's error envelope, over the real ASGI app.

Contract preamble: EVERY non-2xx carries `{"error": {code, message,
detail}}`. Before the three handlers in `api/__init__.py`, FastAPI answered
an unknown route and a malformed body with its own `{"detail": …}` and an
unhandled exception with plain text — shapes `BackendClient.validated`
cannot decode, so the app reported them as INTERNAL "HTTP 404" with nothing
in them to act on.

Driven in-process with a scope/receive/send triple (see
`_fixtures.call_asgi`): no port, no lifespan, no client library.
"""

from __future__ import annotations

import contextlib
import io
import types
import unittest

from _fixtures import FakeState, call_asgi

from supervisor.api import build_app


def _app(**attrs):
    return build_app(FakeState(**attrs))


class ErrorEnvelopeTest(unittest.TestCase):
    def setUp(self) -> None:
        self.app = _app()

    def _assert_envelope(self, res, status: int, code: str) -> None:
        self.assertEqual(res.status, status, res.body)
        payload = res.json()
        self.assertEqual(set(payload), {"error"}, payload)
        self.assertEqual(set(payload["error"]), {"code", "message", "detail"})
        self.assertEqual(payload["error"]["code"], code)
        self.assertIsInstance(payload["error"]["message"], str)
        self.assertIsInstance(payload["error"]["detail"], dict)

    def test_an_unknown_route_is_a_not_found_envelope(self) -> None:
        res = call_asgi(self.app, "GET", "/v1/nonexistent")
        self._assert_envelope(res, 404, "NOT_FOUND")

    def test_a_missing_bearer_token_is_an_unauthorized_envelope(self) -> None:
        res = call_asgi(self.app, "GET", "/v1/jobs", token=None)
        self._assert_envelope(res, 401, "UNAUTHORIZED")

    def test_a_wrong_bearer_token_is_an_unauthorized_envelope(self) -> None:
        res = call_asgi(self.app, "GET", "/v1/jobs", token="not-the-token")
        self._assert_envelope(res, 401, "UNAUTHORIZED")

    def test_auth_runs_before_routing(self) -> None:
        """An unknown route with no token must still be 401, not 404: the
        middleware is what stops an unauthenticated client enumerating the
        surface."""
        res = call_asgi(self.app, "GET", "/v1/nonexistent", token=None)
        self.assertEqual(res.status, 401)

    def test_healthz_needs_no_token(self) -> None:
        """The one exemption; the app polls it before it has anything else."""
        res = call_asgi(self.app, "GET", "/healthz", token=None)
        self.assertEqual(res.status, 200, res.body)

    def test_a_malformed_body_is_a_validation_envelope(self) -> None:
        """`{"duration_s": null}`-class bugs reached the client as uvicorn's
        plain-text 500; a body that is not even JSON has to be a 422."""
        res = call_asgi(self.app, "POST", "/v1/jobs",
                        headers={"content-type": "application/json"},
                        body=b"this is not json")
        self._assert_envelope(res, 422, "VALIDATION")

    def test_a_validation_envelope_names_what_was_wrong(self) -> None:
        res = call_asgi(self.app, "POST", "/v1/jobs",
                        headers={"content-type": "application/json"},
                        body=b"[1, 2, 3]")
        errors = res.error()["detail"]["errors"]
        self.assertTrue(errors)
        self.assertTrue(all(isinstance(e, dict) for e in errors))

    def test_the_wrong_method_is_a_405_envelope(self) -> None:
        """Starlette raises its own HTTPException for a method mismatch; the
        StarletteHTTPException handler is what keeps it in the envelope."""
        res = call_asgi(self.app, "DELETE", "/v1/jobs")
        self._assert_envelope(res, 405, "NOT_FOUND")

    def test_a_handler_that_raises_is_a_500_internal_envelope(self) -> None:
        app = _app()

        @app.get("/v1/_boom")
        async def boom():          # pragma: no cover — raised, never returns
            raise RuntimeError("kaboom")

        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            res = call_asgi(app, "GET", "/v1/_boom")
        self._assert_envelope(res, 500, "INTERNAL")
        self.assertIn("RuntimeError", res.error()["message"])
        self.assertIn("kaboom", res.error()["message"])

    def test_a_handler_that_raises_puts_its_traceback_on_stderr(self) -> None:
        """The app tails stderr into today's engine log; this handler is the
        only thing between an unexpected KeyError and a client with nothing
        but "Internal Server Error"."""
        app = _app()

        @app.get("/v1/_boom")
        async def boom():          # pragma: no cover
            raise RuntimeError("kaboom")

        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            call_asgi(app, "GET", "/v1/_boom")
        self.assertIn("Traceback", stderr.getvalue())
        self.assertIn("kaboom", stderr.getvalue())

    def test_an_error_raised_inside_a_real_handler_is_still_an_envelope(self) -> None:
        """Not a synthetic route: `jobs_get` reaches into `st.queue.jobs`, and
        a queue that raises there used to be a plain-text 500."""
        class Exploding:
            def get(self, _job_id):
                raise KeyError("no such queue")

        app = _app(queue=types.SimpleNamespace(jobs=Exploding()))
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            res = call_asgi(app, "GET", "/v1/jobs/job_abc")
        self._assert_envelope(res, 500, "INTERNAL")
        self.assertIn("KeyError", res.error()["message"])


if __name__ == "__main__":
    unittest.main()
