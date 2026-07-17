.PHONY: test validate validate-example tui docker-build

test:
	bash -n src/FanControlWithEsxiSmart.sh
	bash -n src/setIdracFanSpeed.sh
	bash -n src/fan-control-tui.sh
	bash tests/fan-control.test.sh
	bash tests/tui.test.sh

validate:
	@test -f .env || { echo "Missing .env; run 'make tui' first" >&2; exit 1; }
	docker compose run --rm --no-deps \
		--volume "$(CURDIR)/src/FanControlWithEsxiSmart.sh:/usr/local/bin/fan-control-dev.sh:ro" \
		--entrypoint /usr/local/bin/fan-control-dev.sh \
		idrac-fan-control validate

validate-example:
	DRY_RUN=true OPERATION_MODE=auto TEMPERATURE_SOURCES=idrac \
	IDRAC_IP=10.0.0.10 IDRAC_ID=root IDRAC_PASSWORD=test \
	src/FanControlWithEsxiSmart.sh validate

tui:
	src/fan-control-tui.sh

docker-build:
	docker build -t idrac-fan-control:local .
