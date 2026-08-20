DEVELOPER_DIR ?= /Applications/Xcode-beta.app

.PHONY: stub verify-stub engine-dev verify-engine app-build app-test smoke package dmg verify-packaged

smoke:           ## generate a short clip per fast model through the real engine
	python3 scripts/smoke_test.py --model test-tiny --duration 2
	python3 scripts/smoke_test.py --model musicgen-small --duration 5

package:         ## build dist/LocalMusic.app (ad-hoc signed; IDENTITY=… for real)
	./scripts/package_app.sh

dmg: package     ## package + wrap dist/LocalMusic-<version>.dmg (production)
	./scripts/make_dmg.sh

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

app-build:
	DEVELOPER_DIR=$(DEVELOPER_DIR) xcodebuild -project app/LocalMusic.xcodeproj -scheme LocalMusic -destination 'platform=macOS' build

app-test:
	DEVELOPER_DIR=$(DEVELOPER_DIR) xcodebuild -project app/LocalMusic.xcodeproj -scheme LocalMusic -destination 'platform=macOS' test
