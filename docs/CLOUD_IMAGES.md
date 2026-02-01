# Cloud Image Workflow

This document describes the recommended approach for creating moltdown VMs using Ubuntu Cloud Images.

## Why Cloud Images?

| Aspect | Cloud Image | ISO Installer |
|--------|-------------|---------------|
| Download size | ~600MB | 3-5GB |
| Boot to SSH | ~20 seconds | 8-15 minutes |
| Desktop ready | ~8 minutes | 15-30 minutes |
| Complexity | Low | Medium-High |

Cloud images are pre-installed Ubuntu systems with cloud-init. They boot instantly and configure from a seed ISO.

## Quick Start

```bash
./setup_cloud.sh
```

## Manual Setup

### 1. Download Cloud Image

```bash
wget -O /var/lib/libvirt/images/ubuntu-noble-cloudimg.img \
  https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img
```

### 2. Create VM Disk

```bash
cp /var/lib/libvirt/images/ubuntu-noble-cloudimg.img /var/lib/libvirt/images/my-vm.qcow2
qemu-img resize /var/lib/libvirt/images/my-vm.qcow2 50G
```

### 3. Generate Seed ISO

```bash
./generate_cloud_seed.sh /var/lib/libvirt/images/my-vm-seed.iso
```

### 4. Create VM

```bash
virt-install \
  --name my-agent-vm \
  --vcpus 4 --memory 8192 \
  --disk /var/lib/libvirt/images/my-vm.qcow2 \
  --disk /var/lib/libvirt/images/my-vm-seed.iso,device=cdrom \
  --os-variant ubuntu24.04 \
  --network network=default \
  --graphics spice --video virtio \
  --import --noautoconsole
```

## GUI Access

VMs are created with SPICE graphics for full desktop access.

### Prerequisites

```bash
# Install virt-viewer (minimal) or virt-manager (full GUI)
sudo apt install virt-viewer
# or
sudo apt install virt-manager
```

### Connecting

```bash
# Quick connection with virt-viewer
virt-viewer <vm-name>

# Auto-retry if VM is starting
virt-viewer --auto-retry <vm-name>

# Full management GUI
virt-manager
```

### Display Configuration

moltdown VMs use:
- **Graphics:** SPICE (better performance than VNC)
- **Video:** virtio (GPU acceleration)
- **Channel:** spicevmc (clipboard sharing, dynamic resolution)

### Troubleshooting GUI

```bash
# Check VM graphics config
virsh dumpxml <vm-name> | grep -A10 "<graphics"

# Restart spice-vdagent inside VM (for clipboard/resolution)
sudo systemctl restart spice-vdagent
```

## Long-Running Sessions

moltdown VMs are hardened for multi-day or multi-week agent sessions.

### Built-in Protections

The bootstrap script configures:
- **Swap file:** 4GB swap for memory pressure
- **Journal limits:** 100MB max, 1 week retention
- **Cloud-init disabled:** Prevents reconfiguration on reboot
- **No auto-reboot:** Security updates install but don't restart

### Health Monitoring

```bash
# Inside VM - quick health check
vm-health-check

# Watch mode (updates every 30s)
vm-health-check --watch

# From host - SSH health check
ssh agent@<ip> 'vm-health-check'
```

### Manual Maintenance

```bash
# Clean up journal if needed
sudo journalctl --vacuum-size=50M

# Check swap usage
free -h

# Check disk usage
df -h /
ncdu /  # Interactive disk usage
```

## Cloud-init vs Autoinstall

Cloud images use **cloud-init** format (NOT autoinstall):
- No `autoinstall:` wrapper
- Uses `users:` instead of `identity:`
- Password with `passwd:` field
- Commands under `runcmd:`

See `cloud-init/user-data` for template.

## Troubleshooting

```bash
# Check cloud-init status
ssh agent@<ip> 'cloud-init status'

# View cloud-init logs
ssh agent@<ip> 'cat /var/log/cloud-init-output.log'

# Check if cloud-init is disabled (should be after bootstrap)
ssh agent@<ip> 'ls -la /etc/cloud/cloud-init.disabled'
```
