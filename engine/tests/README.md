# Engine tests

Pure-logic regressions for the engine's Python: no engine process, no model
weights, no GPU, no network. Run them with

    make check-engine            # or: python3 scripts/engine_tests.py [group…]

Each directory runs under the interpreter that owns its imports (see
`scripts/engine_tests.py`): `supervisor/` and `protocol/` under the supervisor
venv, `catalog/` under plain `python3` (stdlib only), and
`adapters/<family>/` under that family's `.venv`. Put a test where its imports
live; a test that needs `torch` belongs in a family directory whose venv has it.

Rules: plain `unittest`; never load weights (mock or build tiny inputs; every
runner sets `HF_HUB_OFFLINE=1`); one behaviour per test, named after the bug
it pins (`test_one_section_lyric_sheet_still_renders`, not `test_parse_2`).
