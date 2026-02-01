# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
### Changed
### Deprecated
### Removed
### Fixed
### Security

## [1.0.0] - 2025-02-01

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

[Unreleased]: https://github.com/williamzujkowski/moltdown/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/williamzujkowski/moltdown/releases/tag/v1.0.0
