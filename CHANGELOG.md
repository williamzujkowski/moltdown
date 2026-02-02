# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- `agent.sh` - One command to spin up and connect to agent VM
- `update-golden.sh` - Update golden image CLIs and auth
- `code-connect.sh` - Open VS Code Remote SSH to agent VM
- `sync-ai-auth.sh` - Sync AI CLI auth and git config to VM
- Pre-installed AI CLIs in golden image: Claude Code, Codex, Gemini
- Pre-installed nexus-agents MCP server
- SSH commit signing configured by default
- Makefile targets: `agent`, `agent-list`, `agent-stop`, `agent-kill`, `update-golden`, `code-connect`, `sync-auth`
- Golden image now includes full authentication (Claude OAuth, GitHub token, Codex, Gemini)
- Clones inherit all authentication - no setup required
- Health check on connect (`./agent.sh --health`)

### Changed
- Updated README with one-command agent workflow
- Updated README with quick reference table
- Updated README with shell aliases

### Fixed
- CI shellcheck warnings (SC2155, SC2088)
- Pinned GitHub Actions to stable versions (ludeeus/action-shellcheck@2.0.0, ibiqlik/action-yamllint@v3.1.1)
- Updated golden image dependencies (npm 11.8.0, corepack 0.34.6, nexus-agents latest)

## [1.1.0] - 2026-02-01

### Added
- `clone_manager.sh` for parallel agent workflows with linked clones
- `setup_cloud.sh` - One-command setup using Ubuntu cloud images (fast!)
- `generate_cloud_seed.sh` - Seed ISO generator for cloud images
- GUI access support via virt-viewer and virt-manager
- Long-running session hardening (swap file, cloud-init disable, journal limits)
- `vm-health-check` script for monitoring VM health
- SSH key authentication in golden image (clones inherit keys)
- Security documentation clarifying local vs repo data
- Makefile targets: `clone`, `clone-linked`, `clone-list`, `clone-cleanup`, `gui`, `start`, `stop`, `status`
- `docs/CLOUD_IMAGES.md` for cloud image workflow documentation

### Fixed
- Sudo detection for libvirt group users (clone_manager.sh, snapshot_manager.sh)
- Clone disk location now uses same directory as source
- Inherited CD-ROM removal from clones (prevents missing ISO errors)

### Changed
- Cloud images now recommended over ISO installer (~8 min vs ~20 min setup)
- Updated README with parallel workflows, GUI access, and security notes
- Updated CLAUDE.md with clone commands and security considerations
- Bootstrap phases now include long-run hardening (swap, journal limits)

### Security
- Added Security Notes section to README explaining what stays local
- Added Security Considerations to CLAUDE.md for AI assistants
- Documented that VM disk images, SSH keys, and credentials never enter git
- `.gitignore` explicitly excludes all disk images and ISOs

## [1.0.0] - 2026-02-01

### Added
- Initial release of moltdown 🦀
- `bootstrap_agent_vm.sh` - Phased, idempotent VM bootstrap with security hardening
- `snapshot_manager.sh` - libvirt snapshot management for agent workflows
- `virt_install_agent_vm.sh` - Automated VM creation with virt-install
- `generate_nocloud_iso.sh` - Cloud-init seed ISO generator
- `run_bootstrap_on_vm.sh` - Remote bootstrap execution via SSH
- Cloud-init autoinstall configuration for Ubuntu 24.04 Desktop
- GitHub Actions workflow for shellcheck and yamllint
- Makefile for common operations

### Security
- SSH hardening (key-only auth, no root login)
- fail2ban for brute-force protection
- UFW firewall configuration
- Unattended security upgrades

[Unreleased]: https://github.com/williamzujkowski/moltdown/compare/v1.1.0...HEAD
[1.1.0]: https://github.com/williamzujkowski/moltdown/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/williamzujkowski/moltdown/releases/tag/v1.0.0
