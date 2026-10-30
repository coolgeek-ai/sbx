.PHONY: lint cores test test-latest
lint:
	bash -n sbx.sh
	shellcheck -S warning sbx.sh tests/*.sh compat/*.sh
cores:
	tests/fetch-cores.sh
test: cores
	tests/run-all.sh
test-latest:
	SING_BOX_VERSION=latest XRAY_VERSION=latest tests/fetch-cores.sh
	tests/run-all.sh
