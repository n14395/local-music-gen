"""`JobQueue.submit` coercions and refusals (audit 08-B8, M13).

`count` and `duration_s` used to be bare `int()`/`float()` calls. A key that
is *present and null* does not take `body.get`'s default, so
`{"duration_s": null}` was a TypeError nothing caught and uvicorn's 500 in
plain text — the one error shape the contract says never goes out. Every
refusal in submit is a `SubmitError`; these used to be the exceptions.
"""

from __future__ import annotations

import unittest

from _fixtures import FakeBus, FakeRegistry, make_queue, model_entry

from supervisor.jobqueue import SubmitError, _number


class NumberCoercionTest(unittest.TestCase):
    """08-B8: the helper every numeric submit field goes through."""

    def _refusal(self, body, key, kind, default):
        try:
            _number(body, key, kind, default)
        except SubmitError as e:
            return (e.status, e.code)
        return None

    def test_a_present_but_null_number_takes_the_default(self) -> None:
        self.assertEqual(_number({"duration_s": None}, "duration_s", float,
                                 30.0), 30.0)

    def test_an_absent_number_takes_the_default(self) -> None:
        self.assertEqual(_number({}, "count", int, 1), 1)

    def test_a_null_default_survives_as_null(self) -> None:
        """Task jobs echo whatever duration was sent; None is a real answer."""
        self.assertIsNone(_number({}, "duration_s", float, None))

    def test_a_numeric_string_is_coerced(self) -> None:
        self.assertEqual(_number({"count": "2"}, "count", int, 1), 2)

    def test_a_float_string_is_coerced(self) -> None:
        self.assertEqual(_number({"duration_s": "12.5"}, "duration_s", float,
                                 30.0), 12.5)

    def test_a_real_number_passes_through(self) -> None:
        self.assertEqual(_number({"count": 3}, "count", int, 1), 3)

    def test_a_word_is_a_422_not_a_500(self) -> None:
        self.assertEqual(self._refusal({"count": "two"}, "count", int, 1),
                         (422, "VALIDATION"))

    def test_a_bool_is_a_422_not_a_silent_one(self) -> None:
        """`bool` is an `int` in Python, so `count: true` used to mean one
        take — which is nobody's intent."""
        self.assertEqual(self._refusal({"count": True}, "count", int, 1),
                         (422, "VALIDATION"))
        self.assertEqual(self._refusal({"count": False}, "count", int, 1),
                         (422, "VALIDATION"))

    def test_a_list_is_a_422(self) -> None:
        self.assertEqual(self._refusal({"count": []}, "count", int, 1),
                         (422, "VALIDATION"))

    def test_an_object_is_a_422(self) -> None:
        self.assertEqual(self._refusal({"count": {}}, "count", int, 1),
                         (422, "VALIDATION"))

    def test_the_refusal_names_the_field(self) -> None:
        with self.assertRaises(SubmitError) as ctx:
            _number({"duration_s": "two"}, "duration_s", float, 30.0)
        self.assertIn("duration_s", str(ctx.exception))


class SubmitTest(unittest.TestCase):
    def setUp(self) -> None:
        self.bus = FakeBus()
        self.registry = FakeRegistry()
        self.queue = make_queue(registry=self.registry, bus=self.bus)

    def _body(self, **over) -> dict:
        body = {"model_ids": ["fake-model"], "prompt": "a warm pad"}
        body.update(over)
        return body

    def _refusal(self, body):
        try:
            self.queue.submit(body)
        except SubmitError as e:
            return (e.status, e.code, str(e))
        return None

    # MARK: accepted

    def test_a_plain_submit_is_accepted(self) -> None:
        out = self.queue.submit(self._body())
        self.assertTrue(out["group_id"].startswith("grp_"))
        self.assertEqual(len(out["jobs"]), 1)
        self.assertEqual(len(self.queue.order), 1)

    def test_a_null_duration_is_accepted_and_takes_the_catalog_default(self) -> None:
        """08-B8, the original crash: `{"duration_s": null}` was a 500."""
        out = self.queue.submit(self._body(duration_s=None))
        job = self.queue.jobs[out["jobs"][0]["job_id"]]
        self.assertEqual(job.duration_s, 30)

    def test_a_null_count_is_accepted_and_means_one_take(self) -> None:
        out = self.queue.submit(self._body(count=None))
        self.assertEqual(len(out["jobs"]), 1)

    def test_a_null_params_object_is_accepted(self) -> None:
        out = self.queue.submit(self._body(params=None))
        job = self.queue.jobs[out["jobs"][0]["job_id"]]
        self.assertEqual(job.params, {})

    def test_a_duration_over_the_ceiling_is_clamped_not_refused(self) -> None:
        out = self.queue.submit(self._body(duration_s=9999))
        job = self.queue.jobs[out["jobs"][0]["job_id"]]
        self.assertEqual(job.duration_s, 60)

    def test_an_unlocked_ceiling_is_honoured_over_max(self) -> None:
        """Clamping to max_s would take an unlocked request and quietly hand
        back a shorter take."""
        entry = model_entry()
        entry["capabilities"]["duration"]["unlocked_max_s"] = 600
        q = make_queue(registry=FakeRegistry([entry]), bus=FakeBus())
        out = q.submit(self._body(duration_s=300))
        self.assertEqual(q.jobs[out["jobs"][0]["job_id"]].duration_s, 300)

    def test_a_count_expands_into_that_many_sibling_jobs(self) -> None:
        """Contract 5.1: `count: 4` is four rows sharing one group_id, each
        with its own position, cancel and error."""
        out = self.queue.submit(self._body(count=3))
        self.assertEqual(len(out["jobs"]), 3)
        jobs = [self.queue.jobs[j["job_id"]] for j in out["jobs"]]
        self.assertEqual([j.take_index for j in jobs], [0, 1, 2])
        self.assertEqual({j.take_of for j in jobs}, {3})
        self.assertEqual({j.group_id for j in jobs}, {out["group_id"]})
        self.assertEqual({j.count for j in jobs}, {1})

    def test_unknown_params_are_dropped_and_announced(self) -> None:
        out = self.queue.submit(self._body(params={"steps": 7, "bogus": 1}))
        job = self.queue.jobs[out["jobs"][0]["job_id"]]
        self.assertEqual(job.params, {"steps": 7})
        logs = [d["line"] for d in self.bus.named("job.log")]
        self.assertEqual(logs, ["dropped unknown param 'bogus'"])

    # MARK: refused

    def test_a_zero_count_is_refused(self) -> None:
        self.assertEqual(self._refusal(self._body(count=0))[:2],
                         (422, "VALIDATION"))

    def test_a_negative_count_is_refused(self) -> None:
        self.assertEqual(self._refusal(self._body(count=-3))[:2],
                         (422, "VALIDATION"))

    def test_a_count_over_the_models_maximum_is_refused(self) -> None:
        self.assertEqual(self._refusal(self._body(count=99))[:2],
                         (422, "VALIDATION"))

    def test_a_params_list_is_refused_not_an_attribute_error(self) -> None:
        """`raw.items()` on a list is an AttributeError, which reached the
        caller as a plain-text 500."""
        self.assertEqual(
            self._refusal(self._body(params=[{"steps": 7}]))[:2],
            (422, "VALIDATION"))

    def test_an_empty_params_list_is_refused_too(self) -> None:
        """`raw = body.get("params") or {}` used to run before the
        `isinstance` guard, so an empty list was quietly accepted as `{}`."""
        self.assertEqual(self._refusal(self._body(params=[]))[:2],
                         (422, "VALIDATION"))

    def test_a_params_string_is_refused(self) -> None:
        self.assertEqual(self._refusal(self._body(params="steps=7"))[:2],
                         (422, "VALIDATION"))

    def test_a_word_for_count_is_refused(self) -> None:
        self.assertEqual(self._refusal(self._body(count="two"))[:2],
                         (422, "VALIDATION"))

    def test_an_unknown_model_is_a_404(self) -> None:
        self.assertEqual(self._refusal(self._body(model_ids=["nope"]))[:2],
                         (404, "NOT_FOUND"))

    def test_an_uninstalled_model_is_a_409(self) -> None:
        q = make_queue(registry=FakeRegistry(installed=False), bus=FakeBus())
        try:
            q.submit(self._body())
        except SubmitError as e:
            self.assertEqual((e.status, e.code), (409, "MODEL_NOT_INSTALLED"))
        else:
            self.fail("an uninstalled model was accepted")

    def test_an_unknown_task_is_refused(self) -> None:
        self.assertEqual(self._refusal(self._body(task="teleport"))[:2],
                         (422, "VALIDATION"))

    def test_two_models_in_one_submit_are_refused(self) -> None:
        body = self._body(model_ids=["fake-model", "fake-model"])
        self.assertEqual(self._refusal(body)[:2], (422, "VALIDATION"))

    def test_an_empty_prompt_is_refused_for_generate(self) -> None:
        self.assertEqual(self._refusal(self._body(prompt="   "))[:2],
                         (422, "VALIDATION"))

    def test_lyrics_for_a_model_that_cannot_sing_are_refused(self) -> None:
        entry = model_entry()
        entry["capabilities"]["supports_lyrics"] = False
        q = make_queue(registry=FakeRegistry([entry]), bus=FakeBus())
        try:
            q.submit(self._body(lyrics="la la la"))
        except SubmitError as e:
            self.assertEqual((e.status, e.code), (422, "VALIDATION"))
        else:
            self.fail("lyrics were accepted by an instrumental model")

    def test_a_preview_request_a_model_cannot_serve_is_refused(self) -> None:
        """Refused rather than ignored: a caller that asked to watch the
        render would otherwise wait for frames that are never coming."""
        self.assertEqual(self._refusal(self._body(preview=True))[:2],
                         (422, "VALIDATION"))

    def test_a_missing_mandatory_file_input_is_refused_before_the_load(self) -> None:
        """Eight generate-only entries declare a mandatory audio slot; without
        this the user bought a multi-GB load and then a RuntimeError."""
        entry = model_entry()
        entry["capabilities"]["params"].append(
            {"key": "src_audio", "type": "audio", "label": "Source",
             "default": None, "nullable": False})
        q = make_queue(registry=FakeRegistry([entry]), bus=FakeBus())
        try:
            q.submit(self._body())
        except SubmitError as e:
            self.assertEqual((e.status, e.code), (422, "VALIDATION"))
            self.assertIn("src_audio", str(e))
        else:
            self.fail("a mandatory audio input was not required")

    def test_a_required_text_is_refused_when_missing_or_blank(self) -> None:
        """A string param that is not nullable and has no default is a
        required text (contract §4.1) — YingMusic's reference words. The
        file-input rule above never looked at strings, so the adapter got
        None for a field the catalog says can never be null (2026-09-16)."""
        entry = model_entry()
        entry["capabilities"]["params"].append(
            {"key": "reference_text", "type": "string", "label": "Words",
             "default": None, "nullable": False})
        for params in ({}, {"reference_text": None}, {"reference_text": "  "}):
            q = make_queue(registry=FakeRegistry([entry]), bus=FakeBus())
            try:
                q.submit(self._body(params=params))
            except SubmitError as e:
                self.assertEqual((e.status, e.code), (422, "VALIDATION"))
                self.assertIn("reference_text", str(e))
            else:
                self.fail(f"a required text was not required for {params!r}")
        q = make_queue(registry=FakeRegistry([entry]), bus=FakeBus())
        q.submit(self._body(params={"reference_text": "la la la"}))

    def test_a_required_when_condition_uses_the_controlling_default(self) -> None:
        """ACE-Step's source audio is optional for text2music and required
        for cover — and the controlling param may be absent from the request,
        in which case its declared default is what the worker would see."""
        entry = model_entry()
        entry["capabilities"]["params"] += [
            {"key": "mode", "type": "enum", "label": "Mode",
             "default": "cover", "nullable": False,
             "choices": [{"value": "cover", "label": "Cover"},
                         {"value": "text2music", "label": "Text"}]},
            {"key": "src_audio", "type": "audio", "label": "Source",
             "default": None, "nullable": True,
             "required_when": {"param": "mode", "values": ["cover"]}},
        ]
        q = make_queue(registry=FakeRegistry([entry]), bus=FakeBus())
        try:
            q.submit(self._body())
        except SubmitError as e:
            self.assertEqual((e.status, e.code), (422, "VALIDATION"))
            self.assertIn("src_audio", str(e))
        else:
            self.fail("required_when did not fire on the declared default")

    def test_an_unknown_upload_id_is_refused(self) -> None:
        entry = model_entry()
        entry["capabilities"]["params"].append(
            {"key": "src_audio", "type": "audio", "label": "Source",
             "default": None, "nullable": True})
        q = make_queue(registry=FakeRegistry([entry]), bus=FakeBus())
        try:
            q.submit(self._body(params={"src_audio": "up_nothing"}))
        except SubmitError as e:
            self.assertEqual((e.status, e.code), (422, "VALIDATION"))
        else:
            self.fail("an unresolvable upload id was accepted")

    def test_lyrics_on_a_task_job_are_refused(self) -> None:
        entry = model_entry()
        entry["capabilities"]["tasks"] = ["analyze"]
        q = make_queue(registry=FakeRegistry([entry]), bus=FakeBus())
        try:
            q.submit({"model_ids": ["fake-model"], "task": "analyze",
                      "lyrics": "la la"})
        except SubmitError as e:
            self.assertEqual((e.status, e.code), (422, "VALIDATION"))
        else:
            self.fail("a task job accepted lyrics")

    def test_a_task_the_model_does_not_declare_is_refused(self) -> None:
        self.assertEqual(self._refusal(self._body(task="separate"))[:2],
                         (422, "VALIDATION"))

    def test_a_task_job_needs_no_prompt(self) -> None:
        entry = model_entry()
        entry["capabilities"]["tasks"] = ["analyze"]
        q = make_queue(registry=FakeRegistry([entry]), bus=FakeBus())
        out = q.submit({"model_ids": ["fake-model"], "task": "analyze"})
        self.assertEqual(len(out["jobs"]), 1)


if __name__ == "__main__":
    unittest.main()
