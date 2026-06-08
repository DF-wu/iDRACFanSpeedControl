.PHONY: test validate docker-build

test:
	bash -n src/FanControlWithEsxiSmart.sh
	bash -n src/setIdracFanSpeed.sh
	bash tests/fan-control.test.sh

validate:
	DRY_RUN=true OPERATION_MODE=auto TEMPERATURE_SOURCES=idrac \
	IDRAC_IP=192.0.2.10 IDRAC_ID=root IDRAC_PASSWORD=test \
	src/FanControlWithEsxiSmart.sh validate

docker-build:
	docker build -t idrac-fan-control:local .
