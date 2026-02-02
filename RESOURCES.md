# Resource Planning for Parallel AI Agents

This guide covers memory, CPU, and disk requirements for running multiple AI CLI agents (Claude, Codex, Gemini) simultaneously in moltdown VM clones.

---

## TL;DR - Quick Reference

| Host RAM | Recommended Clones | RAM per Clone | Config |
|----------|-------------------|---------------|--------|
| 32GB | 1-2 | 12-16GB | Conservative |
| 64GB | 2-4 | 12-16GB | Comfortable |
| 128GB | 4-8 | 12-16GB | Production |

**Critical**: Claude CLI has known memory leaks reaching 13-120GB+ in extended sessions. Plan accordingly.

---

## Why 16GB Default?

The moltdown default of 16GB RAM per VM exists because:

1. **Claude CLI Memory Leaks**: Documented issues show Claude Code consuming 13GB+ during extended sessions, sometimes reaching 120GB before OOM kill
2. **Desktop Overhead**: Ubuntu 24.04 + GNOME requires 400-600MB baseline
3. **Toolchain**: Node.js + Docker + Chrome can consume 1-2GB when active
4. **Swap Buffer**: 8GB swap provides overflow protection, but shouldn't be relied upon

### Memory Breakdown (Active AI Session)

| Component | Idle | Active | Peak |
|-----------|------|--------|------|
| Ubuntu + GNOME | 500MB | 700MB | 1GB |
| Claude CLI | 150MB | 500MB | **13GB+** |
| Chrome (Playwright) | 0 | 300MB | 1GB |
| Docker daemon | 100MB | 200MB | varies |
| Node.js runtime | 100MB | 300MB | 500MB |
| System buffers | 500MB | 1GB | 2GB |
| **Comfortable Total** | 1.5GB | 3GB | **16GB+** |

---

## Clone Memory Architecture

**Each clone allocates independent RAM** - there is no memory sharing between VMs:

```
Host RAM (64GB)
├── Host OS + KVM: 8-10GB reserved
├── Clone 1: 16GB (independent allocation)
├── Clone 2: 16GB (independent allocation)
├── Clone 3: 16GB (independent allocation)
└── Available: 6-14GB buffer
```

Linked clones (`--linked`) only share **disk blocks** via copy-on-write. Memory is never shared.

---

## Deployment Scenarios

### Scenario A: Single Dedicated Agent (Development)

**Host**: Any with 32GB+ RAM

```bash
./setup_cloud.sh --memory 16384 --vcpus 8
```

- Full 16GB for handling memory leaks
- 8 vCPUs for fast compilation/analysis
- No clones needed

### Scenario B: Two Parallel Agents (64GB Host)

**Use Case**: Run different agents on different tasks simultaneously

```bash
# Create golden image with 16GB
./setup_cloud.sh --memory 16384 --vcpus 4

# Create lightweight worker clones
./clone_manager.sh create ubuntu2404-agent --linked --memory 12288 --vcpus 4
./clone_manager.sh create ubuntu2404-agent --linked --memory 12288 --vcpus 4

# Start both
./clone_manager.sh start moltdown-clone-ubuntu2404-agent-*
```

**Memory allocation**:
- Host overhead: 10GB
- Golden image (stopped): 0GB (not running)
- Clone 1: 12GB
- Clone 2: 12GB
- Buffer: 30GB for memory spikes

### Scenario C: Maximum Density (64GB Host, 4 Agents)

**Use Case**: Many short-lived tasks, aggressive snapshotting

```bash
# Create clones with reduced memory
./clone_manager.sh create ubuntu2404-agent --linked --memory 8192 --vcpus 2
./clone_manager.sh create ubuntu2404-agent --linked --memory 8192 --vcpus 2
./clone_manager.sh create ubuntu2404-agent --linked --memory 8192 --vcpus 2
./clone_manager.sh create ubuntu2404-agent --linked --memory 8192 --vcpus 2
```

**Memory allocation**:
- Host overhead: 10GB
- 4 clones × 8GB: 32GB
- Buffer: 22GB

**Mitigation required**:
- Revert clones frequently (`./snapshot_manager.sh post-run`)
- Monitor memory with `vm-health-check --watch`
- Accept OOM risk for long sessions

### Scenario D: Production (128GB+ Host)

```bash
# High-memory golden image
./setup_cloud.sh --memory 24576 --vcpus 8  # 24GB

# Multiple comfortable clones
for i in {1..6}; do
    ./clone_manager.sh create ubuntu2404-agent worker-$i --linked --memory 16384 --vcpus 4
done
```

---

## Agent Resilience Features

The bootstrap installs automated resilience tools to prevent and recover from AI CLI crashes.

### Claude Memory Watchdog (Automatic)

A systemd service that monitors Claude CLI memory and terminates runaway processes:

```bash
# Check watchdog status
systemctl status claude-watchdog

# View watchdog logs
journalctl -u claude-watchdog -f

# Manually start/stop
sudo systemctl start claude-watchdog
sudo systemctl stop claude-watchdog
```

**Thresholds** (configurable in `bootstrap_local.sh`):
- `WATCHDOG_WARN_MB=8000` - Log warning at 8GB
- `WATCHDOG_KILL_MB=13000` - Kill Claude at 13GB

### cgroups Memory Limiting

Run Claude with hard memory limits using the `run-claude-limited` wrapper:

```bash
# Run with default 12GB limit
run-claude-limited

# Run with custom 8GB limit
run-claude-limited 8G

# Run with limit and arguments
run-claude-limited 10G --help
```

The wrapper uses systemd cgroups v2 to enforce hard limits. OOM killer will target Claude if the limit is exceeded.

### Session Persistence

Use `agent-session` for tmux-based session persistence:

```bash
# Start or attach to default session
agent-session

# Start named session in specific directory
agent-session my-project ~/work/repos/my-project
```

Sessions survive disconnects and can be reattached on reconnect. Crash events are logged to `~/.agent-session/crashes.log`.

### Enhanced Health Check

The `vm-health-check` command now includes memory trend prediction:

```bash
# Quick health check
vm-health-check

# Continuous monitoring (30s refresh)
vm-health-check --watch

# Show memory trend analysis
vm-health-check --trend
```

The health check will predict OOM events 30-60 minutes before they occur based on memory growth rate.

---

## Claude CLI Memory Leak Mitigation

Known issue: Claude CLI can consume 13-120GB+ during extended sessions.

### Strategy 1: Frequent Snapshots (Recommended)

```bash
# Before agent run
./snapshot_manager.sh pre-run ubuntu2404-agent

# After completion (or every few hours)
./snapshot_manager.sh post-run ubuntu2404-agent
```

The "molt" workflow releases all leaked memory by reverting to clean state.

### Strategy 2: Memory Limits with cgroups

Inside the VM, limit Claude CLI memory:

```bash
# Create memory-limited slice
sudo mkdir -p /sys/fs/cgroup/claude-agent
echo "8G" | sudo tee /sys/fs/cgroup/claude-agent/memory.max

# Run claude under limit
sudo cgexec -g memory:claude-agent claude
```

### Strategy 3: Watchdog Script

Add to VM's crontab:

```bash
*/15 * * * * /home/agent/bin/claude-memory-watchdog.sh
```

```bash
#!/bin/bash
# claude-memory-watchdog.sh
THRESHOLD_MB=10000  # 10GB

claude_mem=$(ps aux | grep -E 'claude|node.*claude' | awk '{sum+=$6} END {print sum/1024}')
if (( $(echo "$claude_mem > $THRESHOLD_MB" | bc -l) )); then
    logger "Claude CLI exceeded ${THRESHOLD_MB}MB, restarting..."
    pkill -f claude
    notify-send "Claude CLI restarted due to memory pressure"
fi
```

### Strategy 4: Swap as Emergency Buffer

The default 4GB swap is insufficient. Increase to 8GB:

```bash
# In bootstrap_local.sh or manually
SWAP_SIZE="8G"  # Set before running bootstrap
```

---

## Monitoring Commands

### From Host

```bash
# Check all VM memory allocation
for vm in $(sudo virsh list --name); do
    mem=$(sudo virsh dominfo "$vm" | grep "Used memory" | awk '{print $3/1024 "MB"}')
    echo "$vm: $mem"
done

# Watch total memory pressure
watch -n 5 'free -h; echo "---"; sudo virsh list'
```

### Inside VM

```bash
# Quick health check
vm-health-check

# Continuous monitoring
vm-health-check --watch

# Check Claude CLI specifically
ps aux | grep -E 'claude|node' | awk '{printf "%s: %.1fMB\n", $11, $6/1024}'
```

---

## Resource Calculator

Use this formula to plan deployments:

```
Available_for_VMs = Host_RAM - 10GB (host overhead)
Max_Clones = floor(Available_for_VMs / RAM_per_Clone)
Safe_Clones = Max_Clones - 1 (leave buffer for spikes)
```

**Example (64GB host, 12GB per clone)**:
```
Available = 64 - 10 = 54GB
Max = 54 / 12 = 4 clones
Safe = 4 - 1 = 3 clones recommended
```

---

## vCPU Guidelines

| Workload | vCPUs per Clone | Notes |
|----------|-----------------|-------|
| Light (CLI only) | 2 | Text analysis, simple queries |
| Standard | 4 | Code generation, file operations |
| Heavy (builds) | 6-8 | Compilation, Docker builds |
| Browser automation | 4+ | Playwright needs headroom |

**Oversubscription**: KVM handles CPU overcommit well. 4 clones × 4 vCPUs on an 8-core host works fine for non-CPU-bound tasks.

---

## Disk Space

Linked clones are extremely efficient:

| Item | Size | Notes |
|------|------|-------|
| Golden image | 15-25GB | After bootstrap |
| Linked clone (initial) | 1-5MB | Just metadata |
| Linked clone (active) | 1-10GB | Grows with changes |
| Full clone | 15-25GB | Complete copy |

**Recommendation**: Use `--linked` for all parallel workflows. Only use full clones when you need complete isolation or plan to delete the golden image.

---

## Quick Commands

```bash
# Create memory-optimized clone
./clone_manager.sh create ubuntu2404-agent --linked --memory 12288 --vcpus 4

# Check clone resource usage
./clone_manager.sh status

# Revert all clones to clean state (releases memory)
for clone in $(./clone_manager.sh list | grep running | awk '{print $1}'); do
    ./clone_manager.sh stop "$clone"
done
./clone_manager.sh cleanup ubuntu2404-agent
```

---

## References

- [Claude Code Memory Leak Issues](https://github.com/anthropics/claude-code/issues/4953)
- [Claude Code Memory Management Best Practices](https://medium.com/@codecentrevibe/claude-code-best-practices-memory-management-7bc291a87215)
- [libvirt Memory Management](https://libvirt.org/formatdomain.html#memory-allocation)

---

_Last updated: 2026-02-02 (ET) - Added agent resilience features_
