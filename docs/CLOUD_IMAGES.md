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

# View logs
ssh agent@<ip> 'cat /var/log/cloud-init-output.log'
```
