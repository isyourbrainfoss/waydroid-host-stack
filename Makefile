# Desk gates for waydroid-bluetooth
.PHONY: check smoke forwards cargo test

check:
	sh scripts/desk-check.sh

smoke forwards:
	sh tests/smoke-forwards.sh

cargo test:
	cargo test --workspace
