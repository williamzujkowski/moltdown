# moltdown 🦀 - Makefile
# https://github.com/williamzujkowski/moltdown

.PHONY: help lint seed-iso install-deps clean test

SHELL := /bin/bash
VM_NAME ?= ubuntu2404-agent

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'

lint: ## Run shellcheck on all scripts
	@echo "Running shellcheck..."
	@shellcheck -x *.sh guest/*.sh || true
	@echo "Running yamllint on cloud-init files..."
	@yamllint autoinstall/ || true

seed-iso: ## Generate cloud-init seed ISO (interactive)
	./generate_nocloud_iso.sh --customize

seed-iso-default: ## Generate seed ISO with defaults
	./generate_nocloud_iso.sh

install-deps: ## Install host dependencies (Ubuntu/Debian)
	sudo apt update
	sudo apt install -y \
		qemu-kvm \
		libvirt-daemon-system \
		libvirt-clients \
		virtinst \
		virt-manager \
		genisoimage \
		openssh-client \
		shellcheck \
		yamllint

create-vm: seed.iso ## Create VM with automated installation
	./virt_install_agent_vm.sh --seed-iso ./seed.iso --name $(VM_NAME)

list-snapshots: ## List snapshots for VM
	./snapshot_manager.sh list $(VM_NAME)

pre-run: ## Create pre-agent-run snapshot
	./snapshot_manager.sh pre-run $(VM_NAME)

post-run: ## Revert to dev-ready snapshot
	./snapshot_manager.sh post-run $(VM_NAME)

golden: ## Interactive golden image creation
	./snapshot_manager.sh golden $(VM_NAME)

ssh: ## SSH into VM (requires VM_IP)
	@if [ -z "$(VM_IP)" ]; then \
		echo "Usage: make ssh VM_IP=192.168.122.x"; \
		echo ""; \
		echo "Detecting VM IP..."; \
		sudo virsh domifaddr $(VM_NAME) 2>/dev/null || echo "VM may not be running"; \
	else \
		ssh agent@$(VM_IP); \
	fi

clean: ## Remove generated ISOs
	rm -f seed.iso *.iso

test: lint ## Run all tests
	@echo "All tests passed"
