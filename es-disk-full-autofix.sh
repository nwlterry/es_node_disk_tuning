#!/bin/bash
# =============================================================================
# Elasticsearch Full Disk Auto-Fix Script
# Optimized for VMware ESXi + vSAN + RHEL 8+ + Elasticsearch 8.x
# =============================================================================
# Usage: sudo ./es-disk-full-autofix.sh /dev/sdb
#        sudo ./es-disk-full-autofix.sh /dev/sdb --force

set -euo pipefail

DISK="${1:-/dev/sdb}"
FORCE_MODE="${2:-}"
MOUNT_POINT="/data/elasticsearch"

echo "=================================================================="
echo "Elasticsearch Full Disk Auto-Fixer"
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

# Strong Warning
echo "⚠️  WARNING: This script will make significant changes to $DISK"
echo "   - May format the disk (if --force or confirmed)"
echo "   - Will modify system settings (THP, udev, sysctl)"
echo ""

if [[ "$FORCE_MODE" != "--force" ]]; then
    read -p "Type 'YES-FULL-AUTOFIX' to continue: " confirm
    if [[ "$confirm" != "YES-FULL-AUTOFIX" ]]; then
        echo "Operation cancelled by user."
        exit 0
    fi
else
    echo "⚠️  Running in --force mode!"
fi

echo "Starting full auto-fix..."

# 1. Alignment & Formatting (Only if not already XFS)
echo -e "\n[1] Checking & Formatting Disk..."
if lsblk -f "$DISK" | grep -q "xfs"; then
    echo "✓ Already formatted with XFS. Skipping format."
else
    echo "⚠️  Disk is not XFS. Formatting now..."
    if [[ "$FORCE_MODE" == "--force" ]]; then
        echo "Force mode: Formatting $DISK ..."
        mkfs.xfs -f -m crc=1,reflink=1 "$DISK"
    else
        read -p "Type CONFIRM-FORMAT to format $DISK: " confirm
        if [[ "$confirm" == "CONFIRM-FORMAT" ]]; then
            mkfs.xfs -f -m crc=1,reflink=1 "$DISK"
            echo "✓ Disk formatted with XFS"
        else
            echo "Formatting skipped."
        fi
    fi
fi

# 2. Create Mount Point
mkdir -p "$MOUNT_POINT"

# 3. Mount Options + fstab
echo -e "\n[2] Setting Mount Options..."
UUID=$(blkid -s UUID -o value "$DISK")

if ! grep -q "$MOUNT_POINT" /etc/fstab; then
    echo "UUID=$UUID $MOUNT_POINT xfs defaults,noatime,nodiratime,inode64,logbufs=8,logbsize=256k,allocsize=64k 0 2" >> /etc/fstab
    echo "✓ Added optimized fstab entry"
else
    echo "✓ fstab entry already exists. Updating..."
    sed -i "\|$MOUNT_POINT|d" /etc/fstab
    echo "UUID=$UUID $MOUNT_POINT xfs defaults,noatime,nodiratime,inode64,logbufs=8,logbsize=256k,allocsize=64k 0 2" >> /etc/fstab
fi

mount -o remount "$MOUNT_POINT" 2>/dev/null || mount "$MOUNT_POINT"
echo "✓ Mount options applied"

# 4. Readahead
echo -e "\n[3] Setting Readahead to 128 KiB..."
blockdev --setra 256 "$DISK"

cat <<EOF > /etc/udev/rules.d/60-es-readahead.rules
ACTION=="add|change", KERNEL=="$(basename "$DISK")*|sd[b-z]*|nvme[0-9]n[0-9]*|vd[b-z]*", ATTR{queue/read_ahead_kb}="128"
EOF

udevadm control --reload-rules && udevadm trigger
echo "✓ Readahead set to 128 KiB"

# 5. I/O Scheduler
echo -e "\n[4] Setting I/O Scheduler to none..."
echo none > /sys/block/"$(basename "$DISK")"/queue/scheduler

cat <<EOF > /etc/udev/rules.d/61-es-scheduler.rules
ACTION=="add|change", KERNEL=="$(basename "$DISK")*|sd[b-z]*|nvme*|vd*", ATTR{queue/scheduler}="none"
EOF
echo "✓ I/O Scheduler set to none"

# 6. Transparent Huge Pages
echo -e "\n[5] Disabling Transparent Huge Pages..."
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
echo "✓ THP disabled permanently"

# 7. Sysctl Tuning
echo -e "\n[6] Applying sysctl tuning..."
cat <<EOF > /etc/sysctl.d/99-elasticsearch.conf
vm.swappiness = 1
vm.max_map_count = 262144
EOF
sysctl -p /etc/sysctl.d/99-elasticsearch.conf
echo "✓ Sysctl settings applied"

# 8. Permissions
chown -R elasticsearch:elasticsearch "$MOUNT_POINT" 2>/dev/null || true
echo "✓ Permissions set"

echo -e "\n=================================================================="
echo "✅ Full Auto-Fix Completed Successfully!"
echo "=================================================================="
echo "Final Verification Commands:"
echo "  df -hT $MOUNT_POINT"
echo "  lsblk -o NAME,RA,SCHED,MOUNTPOINT $DISK"
echo "  cat /sys/kernel/mm/transparent_hugepage/enabled"
echo "  iostat -x 1 3"
echo ""
echo "Don't forget to update elasticsearch.yml with path.data: $MOUNT_POINT"
echo "=================================================================="
