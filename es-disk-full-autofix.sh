#!/bin/bash
# =============================================================================
# Elasticsearch Full Disk Auto-Fix Script (Updated - Safer Formatting)
# Optimized for VMware ESXi + vSAN + RHEL 8+ + Elasticsearch 8.x
# =============================================================================
# Usage: sudo ./es-disk-full-autofix.sh /dev/sdb
#        sudo ./es-disk-full-autofix.sh /dev/sdb --force

set -euo pipefail

DISK="${1:-/dev/sdb}"
FORCE_MODE="${2:-}"
MOUNT_POINT="/data/elasticsearch"

echo "=================================================================="
echo "Elasticsearch Full Disk Auto-Fixer (Safe Version)"
echo "Target Disk     : $DISK"
echo "Mount Point     : $MOUNT_POINT"
echo "=================================================================="

# Safety Checks
if [[ $EUID -ne 0 ]]; then
    echo "❌ Error: This script must be run as root"
    exit 1
fi

if [[ ! -b "$DISK" ]]; then
    echo "❌ Error: $DISK is not a valid block device"
    exit 1
fi

echo "⚠️  WARNING: This script will apply system-wide tuning."
echo "   Formatting will only occur if you explicitly confirm."
echo ""

if [[ "$FORCE_MODE" != "--force" ]]; then
    read -p "Type 'YES-AUTOFIX' to continue (or Ctrl+C to cancel): " confirm
    if [[ "$confirm" != "YES-AUTOFIX" ]]; then
        echo "Operation cancelled by user."
        exit 0
    fi
else
    echo "⚠️  Running in --force mode!"
fi

echo "Starting auto-fix..."

# 1. Alignment & Formatting (Safer Logic)
echo -e "\n[1] Checking Disk Filesystem..."
if lsblk -f "$DISK" | grep -q "xfs"; then
    echo "✓ Disk is already formatted with XFS → Skipping format"
else
    echo "⚠️  Disk is NOT formatted with XFS."
    echo "   Current filesystem: $(lsblk -f "$DISK" --noheadings | awk '{print $2}' || echo 'unknown')"
    
    if [[ "$FORCE_MODE" == "--force" ]]; then
        echo "Force mode enabled → Formatting $DISK ..."
        mkfs.xfs -f -m crc=1,reflink=1 "$DISK"
        echo "✓ Disk formatted"
    else
        echo "   WARNING: This will ERASE ALL DATA on $DISK"
        read -p "Type 'CONFIRM-FORMAT' to format (or press Enter to SKIP): " confirm_format
        if [[ "$confirm_format" == "CONFIRM-FORMAT" ]]; then
            mkfs.xfs -f -m crc=1,reflink=1 "$DISK"
            echo "✓ Disk formatted with XFS"
        else
            echo "→ Formatting skipped by user (disk may already contain data)"
        fi
    fi
fi

# 2. Create Mount Point
mkdir -p "$MOUNT_POINT"

# 3. Mount Options + fstab
echo -e "\n[2] Setting Optimized Mount Options..."
UUID=$(blkid -s UUID -o value "$DISK" || echo "")

if [[ -z "$UUID" ]]; then
    echo "⚠️  Could not get UUID. Please mount manually after script."
else
    if ! grep -q "$MOUNT_POINT" /etc/fstab; then
        echo "UUID=$UUID $MOUNT_POINT xfs defaults,noatime,nodiratime,inode64,logbufs=8,logbsize=256k,allocsize=64k 0 2" >> /etc/fstab
        echo "✓ Added optimized fstab entry"
    else
        sed -i "\|$MOUNT_POINT|d" /etc/fstab
        echo "UUID=$UUID $MOUNT_POINT xfs defaults,noatime,nodiratime,inode64,logbufs=8,logbsize=256k,allocsize=64k 0 2" >> /etc/fstab
        echo "✓ Updated fstab entry"
    fi
fi

mount -o remount "$MOUNT_POINT" 2>/dev/null || mount "$MOUNT_POINT" || true

# 4. Readahead
echo -e "\n[3] Setting Readahead to 128 KiB..."
blockdev --setra 256 "$DISK"

cat <<EOF > /etc/udev/rules.d/60-es-readahead.rules
ACTION=="add|change", KERNEL=="$(basename "$DISK")*|sd[b-z]*|nvme[0-9]n[0-9]*|vd[b-z]*", ATTR{queue/read_ahead_kb}="128"
EOF
udevadm control --reload-rules && udevadm trigger
echo "✓ Readahead applied"

# 5. I/O Scheduler
echo -e "\n[4] Setting I/O Scheduler to none..."
echo none > /sys/block/"$(basename "$DISK")"/queue/scheduler || true

cat <<EOF > /etc/udev/rules.d/61-es-scheduler.rules
ACTION=="add|change", KERNEL=="$(basename "$DISK")*|sd[b-z]*|nvme*|vd*", ATTR{queue/scheduler}="none"
EOF
echo "✓ I/O Scheduler applied"

# 6. Transparent Huge Pages + Sysctl + Final Steps
echo -e "\n[5] Applying THP, Sysctl & Permissions..."

# THP
echo never > /sys/kernel/mm/transparent_hugepage/enabled
echo never > /sys/kernel/mm/transparent_hugepage/defrag

cat <<EOF > /etc/systemd/system/disable-thp.service
[Unit]
Description=Disable Transparent Huge Pages for Elasticsearch
After=sysinit.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'echo never > /sys/kernel/mm/transparent_hugepage/enabled'
ExecStart=/bin/sh -c 'echo never > /sys/kernel/mm/transparent_hugepage/defrag'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now disable-thp.service

# Sysctl
cat <<EOF > /etc/sysctl.d/99-elasticsearch.conf
vm.swappiness = 1
vm.max_map_count = 262144
EOF
sysctl -p /etc/sysctl.d/99-elasticsearch.conf

# Permissions
chown -R elasticsearch:elasticsearch "$MOUNT_POINT" 2>/dev/null || true

echo -e "\n=================================================================="
echo "✅ Auto-Fix Completed!"
echo "=================================================================="
echo "Next Steps:"
echo "1. Verify: df -hT $MOUNT_POINT"
echo "2. Update elasticsearch.yml → path.data: $MOUNT_POINT"
echo "3. Restart Elasticsearch"
echo "=================================================================="
