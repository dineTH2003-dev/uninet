.PHONY: test lint install uninstall help

help:
	@echo "UniNet Developer Commands:"
	@echo "  make test        Run captive portal simulation test suite"
	@echo "  make lint        Validate shell syntax for all scripts"
	@echo "  make install     Run local installer"
	@echo "  make uninstall   Run uninstaller"

lint:
	@echo "Linting shell scripts..."
	@bash -n bin/uninet
	@bash -n bin/uninet-macos
	@bash -n install.sh
	@bash -n uninstall.sh
	@bash -n scripts/linux/99-uninet.sh
	@bash -n tests/test_simulation.sh
	@echo "✔ All shell scripts passed syntax checks!"

test: lint
	@echo "Running test suite..."
	@bash tests/test_simulation.sh

install:
	@./install.sh

uninstall:
	@./uninstall.sh
