DEVELOPER_DIR ?= /Applications/Xcode-beta.app

# Build, packaging and .dmg creation live in ./build.sh — see `./build.sh --help`.
# What is left here is the engine/contract tooling that build.sh does not cover.
.PHONY: stub verify-stub engine-dev verify-engine app-test smoke verify-packaged check-supervisor check-engine check-locks check-pins check

smoke:           ## generate a short clip per fast model through the real engine
	python3 scripts/smoke_test.py --model test-tiny --duration 2
	python3 scripts/smoke_test.py --model musicgen-small --duration 5

verify-packaged: ## first-run test of the packaged engine
	python3 scripts/verify_packaged.py

stub:            ## run the contract stub on a fixed dev path (attach mode fixture)
	./stub-backend/run-stub.sh

verify-stub:     ## end-to-end contract checks against the stub
	python3 scripts/verify_stub.py

engine-dev:      ## run the real supervisor with dev paths
	./engine/scripts/dev.sh

verify-engine:   ## contract + engine checks against the real supervisor
	python3 scripts/verify_engine.py

check-supervisor: ## fast checks for the supervisor's pure logic (no engine, no GPU)
	python3 scripts/check_supervisor.py

check-engine:    ## the engine's Python tests, each group under its own venv (no engine, no GPU)
	python3 scripts/engine_tests.py

check-locks:     ## every uv.lock still matches its pyproject (offline; a drifted lock kills a model on first run)
	@fail=0; for p in engine/supervisor engine/adapters/*/; do \
	  if [ -f "$$p/uv.lock" ]; then \
	    uv lock --check --offline --project "$$p" >/dev/null 2>&1 || { echo "DRIFT $$p"; fail=1; }; \
	  fi; \
	done; [ $$fail -eq 0 ] && echo "all locks current"; exit $$fail

check-pins:      ## adapter venvs vs the triage envs that proved them (needs the model SSD)
	python3 scripts/check_pin_drift.py

check: check-supervisor check-engine check-locks ## everything that runs without an engine or a GPU

app-test:
	DEVELOPER_DIR=$(DEVELOPER_DIR) xcodebuild -project app/LocalMusicGen.xcodeproj -scheme LocalMusicGen -destination 'platform=macOS' test
