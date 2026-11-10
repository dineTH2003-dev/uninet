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

test: lint test-windows
	@echo "Running Linux simulation test suite..."
	@bash tests/test_simulation.sh

test-windows:
	@if command -v pwsh >/dev/null 2>&1; then \
		echo "Running Windows PowerShell test suite..."; \
		pwsh -NoProfile -File tests/test_windows.ps1; \
	elif [ -x "$$HOME/.dotnet/tools/pwsh" ]; then \
		echo "Running Windows PowerShell test suite via dotnet tool..."; \
		$$HOME/.dotnet/tools/pwsh -NoProfile -File tests/test_windows.ps1; \
	else \
		echo "Notice: pwsh not found on system PATH. Skipping local PowerShell test."; \
	fi

install:
	@./install.sh

uninstall:
	@./uninstall.sh
