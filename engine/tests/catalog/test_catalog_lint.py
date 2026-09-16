"""The catalog linter: invariants `engine/catalog/models.json` must hold.

The catalog is generated (`scripts/build_catalog.py`) and hand-edited, and
nothing between the generator and a worker checks it. Every rule here is one
the engine, an adapter or the app silently assumes — 09-B9 most of all: an
adapter's fallback constant and the catalog default for the same knob must
be the same number, or a render made with "the defaults" is not the render
the entry describes.

A failure here is a **catalog** finding, not a test to relax: fix the entry.
"""

from __future__ import annotations

import unittest

from _fixtures import (FILE_TYPES, NUMERIC_TYPES, SANE_SAMPLE_RATES,
                       SETTING_TO_PARAMS, choice_values, describe, load_models,
                       param_named, params_of)

MODELS = load_models()


class CatalogShapeTest(unittest.TestCase):
    def test_the_catalog_is_not_empty(self) -> None:
        self.assertGreater(len(MODELS), 0)

    def test_every_model_id_is_unique(self) -> None:
        """Registry keys its dict by id; a duplicate silently shadows the
        earlier entry and the shadowed one can never be downloaded."""
        seen: dict[str, int] = {}
        for m in MODELS:
            seen[m["id"]] = seen.get(m["id"], 0) + 1
        self.assertEqual([i for i, n in seen.items() if n > 1], [])

    def test_every_hf_repo_declares_a_repo_id(self) -> None:
        """`Registry.repo_cache_dir` builds the cache path from it; an entry
        without one downloads into `models--` and is never found again."""
        bad = [describe(m) for m in MODELS
               for r in (m.get("hf_repos") or []) if not r.get("repo_id")]
        self.assertEqual(bad, [])

    def test_every_model_declares_a_family_and_capabilities(self) -> None:
        bad = [m.get("id") for m in MODELS
               if not m.get("family") or not m.get("capabilities")]
        self.assertEqual(bad, [])

    def test_no_model_declares_the_same_param_key_twice(self) -> None:
        """`submit` builds `{p["key"] for p in caps["params"]}`; the second
        one wins in the app's form and neither wins predictably."""
        bad = []
        for m in MODELS:
            keys = [p["key"] for p in params_of(m)]
            bad += [describe(m) + "." + k for k in set(keys)
                    if keys.count(k) > 1]
        self.assertEqual(sorted(bad), [])


class ParamDefaultTest(unittest.TestCase):
    def test_every_numeric_default_is_inside_its_own_range(self) -> None:
        """The app clamps to [min, max]; a default outside it is a control
        that moves the moment the user touches it."""
        bad = []
        for m in MODELS:
            for p in params_of(m):
                if p.get("type") not in NUMERIC_TYPES:
                    continue
                default = p.get("default")
                if default is None:
                    continue
                lo, hi = p.get("min"), p.get("max")
                if lo is not None and default < lo:
                    bad.append(f"{describe(m, p)} default {default} < min {lo}")
                if hi is not None and default > hi:
                    bad.append(f"{describe(m, p)} default {default} > max {hi}")
        self.assertEqual(bad, [])

    def test_every_numeric_param_declares_both_bounds(self) -> None:
        bad = [describe(m, p) for m in MODELS for p in params_of(m)
               if p.get("type") in NUMERIC_TYPES
               and (p.get("min") is None or p.get("max") is None)]
        self.assertEqual(bad, [])

    def test_no_numeric_param_has_its_bounds_the_wrong_way_round(self) -> None:
        bad = [describe(m, p) for m in MODELS for p in params_of(m)
               if p.get("type") in NUMERIC_TYPES
               and p.get("min") is not None and p.get("max") is not None
               and p["min"] > p["max"]]
        self.assertEqual(bad, [])

    def test_every_enum_default_is_one_of_its_choices(self) -> None:
        """An enum whose default is not offered draws an empty picker."""
        bad = []
        for m in MODELS:
            for p in params_of(m):
                if p.get("type") != "enum" or p.get("default") is None:
                    continue
                if p["default"] not in choice_values(p):
                    bad.append(f"{describe(m, p)} default {p['default']!r} "
                               f"not in {choice_values(p)}")
        self.assertEqual(bad, [])

    def test_every_enum_offers_at_least_one_choice(self) -> None:
        bad = [describe(m, p) for m in MODELS for p in params_of(m)
               if p.get("type") == "enum" and not choice_values(p)]
        self.assertEqual(bad, [])

    def test_no_enum_offers_the_same_value_twice(self) -> None:
        bad = [describe(m, p) for m in MODELS for p in params_of(m)
               if p.get("type") == "enum"
               and len(set(choice_values(p))) != len(choice_values(p))]
        self.assertEqual(bad, [])

    def test_a_nullable_param_never_carries_a_non_null_default(self) -> None:
        """Half of "default is null iff nullable". A nullable param with a
        default is a control the user cannot clear back to what it says."""
        bad = [f"{describe(m, p)} = {p.get('default')!r}"
               for m in MODELS for p in params_of(m)
               if p.get("nullable") and p.get("default") is not None]
        self.assertEqual(bad, [])

    def test_a_null_default_means_the_param_is_nullable(self) -> None:
        """The other half.

        File-valued params are exempt by design: `nullable: false` on one of
        those means "mandatory outright" and its default MUST be null — see
        `test_a_mandatory_file_input_defaults_to_null` below. A string param
        reads the same way since 2026-09-16: `sing-yingmusic.reference_text`
        and `lyrics_text` are `"default": null, "nullable": false` on
        purpose, and `submit` now refuses a job that leaves such a text
        missing or blank (contract §4.1) instead of handing the adapter None
        for a field the catalog says can never be null.
        """
        bad = [f"{describe(m, p)} ({p.get('type')})"
               for m in MODELS for p in params_of(m)
               if p.get("type") not in FILE_TYPES
               and p.get("type") != "string"
               and p.get("default") is None and not p.get("nullable", False)]
        self.assertEqual(bad, [])

    def test_a_required_text_has_no_default(self) -> None:
        """A string param that is not nullable and has no default is a
        required text (contract §4.1): the rule only makes sense while it
        really has no default the worker would otherwise have used."""
        required = [describe(m, p) for m in MODELS for p in params_of(m)
                    if p.get("type") == "string"
                    and not p.get("nullable", True)
                    and p.get("default") is None]
        # Today exactly YingMusic's two texts; a new one should be deliberate.
        self.assertEqual(sorted(required),
                         sorted(describe(m, p) for m in MODELS
                                for p in params_of(m)
                                if m["id"] == "sing-yingmusic"
                                and p["key"] in ("reference_text",
                                                 "lyrics_text")))

    def test_a_mandatory_file_input_defaults_to_null(self) -> None:
        """`submit` refuses a missing non-nullable audio/midi/json param for
        every task. That is only safe while such a param has no default the
        worker would otherwise have used — a default here turns into a 422
        the user cannot answer."""
        bad = [describe(m, p) for m in MODELS for p in params_of(m)
               if p.get("type") in FILE_TYPES
               and not p.get("nullable", True)
               and p.get("default") is not None]
        self.assertEqual(bad, [])

    def test_every_conditional_param_names_a_param_that_exists(self) -> None:
        """`required_when`/`applies_when` are looked up by key at submit time
        and in the app's form; a stale key is a condition that never fires."""
        bad = []
        for m in MODELS:
            keys = {p["key"] for p in params_of(m)}
            for p in params_of(m):
                for field in ("required_when", "applies_when"):
                    cond = p.get(field)
                    if cond and cond.get("param") not in keys:
                        bad.append(f"{describe(m, p)}.{field} -> "
                                   f"{cond.get('param')!r}")
        self.assertEqual(bad, [])

    def test_every_required_when_value_is_a_real_choice(self) -> None:
        bad = []
        for m in MODELS:
            for p in params_of(m):
                cond = p.get("required_when")
                if not cond:
                    continue
                ctl = param_named(m, cond["param"])
                if ctl is None or ctl.get("type") != "enum":
                    continue
                vals = set(choice_values(ctl))
                missing = [v for v in cond["values"] if v not in vals]
                if missing:
                    bad.append(f"{describe(m, p)} requires {missing}")
        self.assertEqual(bad, [])


class CapabilitiesTest(unittest.TestCase):
    def test_requiring_lyrics_implies_supporting_them(self) -> None:
        """`submit` refuses lyrics when `supports_lyrics` is false, so an
        entry that requires them without supporting them could never run."""
        bad = [describe(m) for m in MODELS
               if m["capabilities"].get("requires_lyrics")
               and not m["capabilities"].get("supports_lyrics")]
        self.assertEqual(bad, [])

    def test_duration_min_default_max_are_in_order(self) -> None:
        """`submit` clamps to [min_s, ceiling]; a default outside that is a
        take the user never asked for."""
        bad = []
        for m in MODELS:
            d = m["capabilities"]["duration"]
            if not d["min_s"] <= d["default_s"] <= d["max_s"]:
                bad.append(f"{describe(m)} {d['min_s']}/{d['default_s']}"
                           f"/{d['max_s']}")
        self.assertEqual(bad, [])

    def test_the_unlocked_ceiling_is_never_below_the_locked_one(self) -> None:
        """`unlocked_max_s` is the ceiling when a model declares one; below
        max_s it would make unlocking the slider shorten the take."""
        bad = []
        for m in MODELS:
            d = m["capabilities"]["duration"]
            unlocked = d.get("unlocked_max_s")
            if unlocked is not None and unlocked < d["max_s"]:
                bad.append(f"{describe(m)} unlocked {unlocked} < max "
                           f"{d['max_s']}")
        self.assertEqual(bad, [])

    def test_every_model_can_produce_at_least_one_output(self) -> None:
        """`count > outputs_per_job_max` is a 422; at 0 every submit is."""
        bad = [describe(m) for m in MODELS
               if (m["capabilities"].get("outputs_per_job_max") or 0) < 1]
        self.assertEqual(bad, [])

    def test_every_sample_rate_is_a_real_one(self) -> None:
        bad = [f"{describe(m)} {m['capabilities'].get('sample_rate')!r}"
               for m in MODELS
               if m["capabilities"].get("sample_rate") not in SANE_SAMPLE_RATES]
        self.assertEqual(bad, [])


class AdapterFallbackAgreementTest(unittest.TestCase):
    """09-B9: `settings.<x>_default` is what the adapter uses when the catalog
    declares no param for that knob. Where both exist they must be the same
    number, or the take the entry describes is not the take it renders."""

    def test_settings_steps_default_matches_the_steps_param(self) -> None:
        self.assertEqual(self._mismatches("steps_default"), [])

    def test_settings_cfg_scale_default_matches_the_cfg_scale_param(self) -> None:
        self.assertEqual(self._mismatches("cfg_scale_default"), [])

    def test_settings_guidance_scale_default_matches_its_param(self) -> None:
        self.assertEqual(self._mismatches("guidance_scale_default"), [])

    def _mismatches(self, setting_key: str) -> list[str]:
        out = []
        for m in MODELS:
            settings = m.get("settings") or {}
            if setting_key not in settings:
                continue
            for param_key in SETTING_TO_PARAMS[setting_key]:
                p = param_named(m, param_key)
                if p is None:
                    continue
                if p.get("default") != settings[setting_key]:
                    out.append(f"{describe(m)}: settings.{setting_key}="
                               f"{settings[setting_key]!r} vs {param_key} "
                               f"default={p.get('default')!r}")
        return out

    def test_a_declared_sampler_type_is_one_the_param_offers(self) -> None:
        """`settings.sampler_type` picks the scheduler the adapter builds; a
        value the picker does not offer is a setting the user cannot get
        back to once they have changed it."""
        bad = []
        for m in MODELS:
            declared = (m.get("settings") or {}).get("sampler_type")
            if declared is None:
                continue
            p = param_named(m, "sampler_type")
            if p is None:
                continue
            if declared not in choice_values(p):
                bad.append(f"{describe(m)} settings.sampler_type="
                           f"{declared!r} not in {choice_values(p)}")
        self.assertEqual(bad, [])


if __name__ == "__main__":
    unittest.main()
