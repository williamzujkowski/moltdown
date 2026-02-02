# moltdown 🦀 - Makefile
# https://github.com/williamzujkowski/moltdown

.PHONY: help lint seed-iso cloud-seed install-deps clean test setup-cloud setup gui start stop status clone clone-linked clone-list clone-cleanup sync-auth agent agent-list agent-stop agent-kill update-golden code-connect

SHELL := /bin/bash
VM_NAME ?= ubuntu2404-agent
CLOUD_IMG ?= /var/lib/libvirt/images/ubuntu-noble-cloudimg.img

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'

lint: ## Run shellcheck on all scripts
	@echo "Running shellcheck..."
	@shellcheck -x *.sh guest/*.sh || true
	@echo "Running yamllint on cloud-init files..."
	@yamllint autoinstall/ cloud-init/ || true

seed-iso: ## Generate cloud-init seed ISO (interactive)
	./generate_nocloud_iso.sh --customize

seed-iso-default: ## Generate seed ISO with defaults
	./generate_nocloud_iso.sh

cloud-seed: ## Generate cloud-init seed ISO (for cloud images)
	./generate_cloud_seed.sh

setup-cloud: ## Create VM using cloud images (RECOMMENDED - fast!)
	./setup_cloud.sh --vm-name $(VM_NAME)

setup: ## Create VM using ISO installer (slower alternative)
	./setup.sh --vm-name $(VM_NAME)

download-cloud-image: ## Download Ubuntu cloud image
	@if [ -f "$(CLOUD_IMG)" ]; then \
		echo "Cloud image already exists: $(CLOUD_IMG)"; \
	else \
		echo "Downloading Ubuntu 24.04 cloud image (~600MB)..."; \
		sudo wget -O $(CLOUD_IMG) https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img; \
	fi

install-deps: ## Install host dependencies (Ubuntu/Debian)
	sudo apt update
	sudo apt install -y \
		qemu-kvm \
		qemu-utils \
		libvirt-daemon-system \
		libvirt-clients \
		virtinst \
		virt-manager \
		virt-viewer \
		genisoimage \
		xorriso \
		cloud-image-utils \
		openssh-client \
		sshpass \
		shellcheck \
		yamllint \
		wget

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

clone: ## Create a full clone of VM
	./clone_manager.sh create $(VM_NAME)

clone-linked: ## Create a linked clone (fast, copy-on-write)
	./clone_manager.sh create $(VM_NAME) --linked

clone-list: ## List all clones
	./clone_manager.sh list

clone-cleanup: ## Delete all clones of VM
	./clone_manager.sh cleanup $(VM_NAME)

ssh: ## SSH into VM (requires VM_IP)
	@if [ -z "$(VM_IP)" ]; then \
		echo "Usage: make ssh VM_IP=192.168.122.x"; \
		echo ""; \
		echo "Detecting VM IP..."; \
		sudo virsh domifaddr $(VM_NAME) 2>/dev/null || echo "VM may not be running"; \
	else \
		ssh agent@$(VM_IP); \
	fi

gui: ## Open VM desktop with virt-viewer
	@if command -v virt-viewer >/dev/null 2>&1; then \
		virt-viewer --auto-retry $(VM_NAME); \
	else \
		echo "virt-viewer not found. Install with: sudo apt install virt-viewer"; \
	fi

start: ## Start the VM
	sudo virsh start $(VM_NAME)

stop: ## Stop the VM gracefully
	sudo virsh shutdown $(VM_NAME)

status: ## Show VM status and IP
	@echo "=== VM Status ==="
	@sudo virsh domstate $(VM_NAME) 2>/dev/null || echo "VM not found"
	@echo ""
	@echo "=== VM IP ==="
	@sudo virsh domifaddr $(VM_NAME) 2>/dev/null || echo "No IP (VM may not be running)"

sync-auth: ## Sync AI CLI auth and git config to VM (requires VM_IP)
	@if [ -z "$(VM_IP)" ]; then \
		echo "Usage: make sync-auth VM_IP=192.168.122.x [VM_USER=agent]"; \
		exit 1; \
	fi
	./sync-ai-auth.sh $(VM_IP) $(or $(VM_USER),agent)

# Agent workflow commands
agent: ## Spin up a new agent VM and connect (one command!)
	./agent.sh

agent-list: ## List all agent clones
	./agent.sh --list

agent-attach: ## Attach to existing agent clone (use CLONE=name)
	./agent.sh --attach $(CLONE)

agent-stop: ## Stop an agent clone (use CLONE=name)
	@if [ -z "$(CLONE)" ]; then \
		echo "Usage: make agent-stop CLONE=moltdown-clone-xxx"; \
		exit 1; \
	fi
	./agent.sh --stop $(CLONE)

agent-kill: ## Delete an agent clone (use CLONE=name)
	@if [ -z "$(CLONE)" ]; then \
		echo "Usage: make agent-kill CLONE=moltdown-clone-xxx"; \
		exit 1; \
	fi
	./agent.sh --kill $(CLONE)

agent-health: ## Health check on agent clone (use CLONE=name or most recent)
	./agent.sh --health $(CLONE)

update-golden: ## Update golden image (CLIs, packages, auth)
	./update-golden.sh

update-golden-quick: ## Quick update golden image (CLIs only)
	./update-golden.sh --quick

code-connect: ## Open VS Code connected to agent VM
	./code-connect.sh

clean: ## Remove generated ISOs
	rm -f seed.iso *.iso

test: lint ## Run all tests
	@echo "All tests passed"
