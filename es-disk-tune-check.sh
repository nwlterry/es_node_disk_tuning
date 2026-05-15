#!/bin/bash
# Elasticsearch Data Disk Tuning Checker & Fixer (Latest)
# Usage: sudo ./es-disk-tune-check.sh /dev/sdb

DISK="${1:-/dev/sdb}"
MOUNT_POINT="/data/elasticsearch"

echo "=== Elasticsearch Disk Tuning Checker & Fixer (Latest) ==="
echo "Target Disk : $DISK"
echo "============================================"

# 1. Alignment & Sector Size
echo -e "\n[1] Alignment & Sector Size"
blockdev --report "$DISK" 2>/dev/null || echo "blockdev report unavailable"
echo "Logical : $(blockdev --getss "$DISK" 2>/dev/null || echo 'N/A')"
echo "Physical: $(blockdev --getpbsz "$DISK" 2>/dev/null || echo 'N/A')"

# 2. Readahead
echo -e "\n[2] Readahead"
CURRENT_RA=$(lsblk -o NAME,RA --noheadings "$DISK" | awk '{print $2}' | head -1)
echo "Current : ${CURRENT_RA} KiB (Expected: 128)"
if [ "${CURRENT_RA}" != "128" ]; then
    echo "→ FIX NEEDED"
    read -p "Apply readahead fix? (y/n): " -n 1 -r
    if [[ $$   REPLY =~ ^[Yy]   $$ ]]; then
        blockdev --setra 256 "$DISK"
        cat <<EOF > /etc/udev/rules.d/60-es-readahead.rules
ACTION=="add|change", KERNEL=="$(basename "$DISK")*|sd[b-z]*|nvme*|vd*", ATTR{queue/read_ahead_kb}="128"
EOF
        udevadm control --reload-rules && udevadm trigger
        echo "→ Applied"
    fi
else
    echo "→ OK"
fi

# 3. I/O Scheduler
echo -e "\n[3] I/O Scheduler"
SCHED=$$   (cat /sys/block/"   $$(basename "$DISK")"/queue/scheduler 2>/dev/null | sed -E 's/.*$$   (.*)   $$.*/\1/')
echo "Current : $SCHED (Expected: none)"
if [ "$SCHED" != "none" ]; then
    echo "→ FIX NEEDED"
    read -p "Apply scheduler fix? (y/n): " -n 1 -r
    if [[ $$   REPLY =~ ^[Yy]   $$ ]]; then
        echo none > /sys/block/"$(basename "$DISK")"/queue/scheduler
        echo "→ Applied"
    fi
else
    echo "→ OK"
fi

# 4. Mount Options
echo -e "\n[4] Mount Options"
if mount | grep -q "$MOUNT_POINT"; then
    mount | grep "$MOUNT_POINT"
    if mount | grep "$MOUNT_POINT" | grep -q "logbsize=256k"; then
        echo "→ Full recommended options present → OK"
    else
        echo "→ Missing XFS tuning params → FIX NEEDED in /etc/fstab"
    fi
fi

# 5. Transparent Huge Pages
echo -e "\n[5] Transparent Huge Pages"
THP_EN=$(cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null)
THP_DEF=$(cat /sys/kernel/mm/transparent_hugepage/defrag 2>/dev/null)
echo "enabled: $THP_EN | defrag: $THP_DEF"
if [[ ! "$THP_EN" =~ never ]] || [[ ! "$THP_DEF" =~ never ]]; then
    echo "→ FIX NEEDED"
    read -p "Disable THP now? (y/n): " -n 1 -r
    if [[ $$   REPLY =~ ^[Yy]   $$ ]]; then
        echo never > /sys/kernel/mm/transparent_hugepage/enabled
        echo never > /sys/kernel/mm/transparent_hugepage/defrag
        echo "→ Applied (temporary)"
    fi
else
    echo "→ OK"
fi

echo -e "\n=== Summary ==="
echo "Run the script again after fixes."
