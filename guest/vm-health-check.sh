#!/bin/bash
#===============================================================================
# vm-health-check.sh - Quick VM health status for long-running sessions
#===============================================================================
# Part of moltdown 🦀 - https://github.com/williamzujkowski/moltdown
#
# Purpose: Display quick health metrics for monitoring long-running agent VMs
#
# Usage:   vm-health-check
#          vm-health-check --watch    # Refresh every 30 seconds
#
# License: MIT
#===============================================================================

set -euo pipefail

show_health() {
    echo "=== VM Health Check $(date '+%Y-%m-%d %H:%M:%S') ==="
    echo "Uptime:  $(uptime -p)"
    echo "Memory:  $(free -h | awk '/Mem:/{print $3 "/" $2 " (" int($3/$2*100) "% used)"}')"
    echo "Swap:    $(free -h | awk '/Swap:/{if($2!="0B") print $3 "/" $2; else print "not configured"}')"
    echo "Disk:    $(df -h / | awk 'NR==2{print $3 "/" $2 " (" $5 " used)"}')"
    echo "Load:    $(cat /proc/loadavg | cut -d' ' -f1-3)"
    echo "Procs:   $(ps aux --no-headers | wc -l)"

    # Journal size (if available)
    if command -v journalctl &>/dev/null; then
        echo "Journal: $(journalctl --disk-usage 2>/dev/null | grep -oP '\d+\.\d+[MG]' || echo 'unknown')"
    fi

    # Docker status (if installed)
    if command -v docker &>/dev/null; then
        local containers
        containers=$(docker ps -q 2>/dev/null | wc -l)
        echo "Docker:  $containers containers running"
    fi
}

main() {
    case "${1:-}" in
        --watch|-w)
            while true; do
                clear
                show_health
                echo ""
                echo "(Refreshing every 30s, Ctrl+C to exit)"
                sleep 30
            done
            ;;
        --help|-h)
            echo "Usage: vm-health-check [--watch]"
            echo ""
            echo "Display quick health metrics for the VM."
            echo ""
            echo "Options:"
            echo "  --watch, -w    Refresh every 30 seconds"
            echo "  --help, -h     Show this help"
            ;;
        *)
            show_health
            ;;
    esac
}

main "$@"
