**Updated Summary – Elasticsearch Data Disk Tuning & Alignment**  
**(VMware ESXi 7+ / vSAN / RHEL 8+ / ES 8.14.3+)**

### **Summary of Required Settings**
| Item                    | Expected Value                  | Critical? | Action if Wrong |
|-------------------------|---------------------------------|-----------|-----------------|
| Filesystem              | XFS                             | Yes       | Reformat |
| Alignment               | 1 MiB (2048 sectors)            | No        | Use `parted -a optimal` |
| Readahead               | **128 KiB**                     | **Yes**   | Change from 8192 |
| Mount Options           | `noatime,nodiratime,inode64`    | Yes       | Update fstab |
| I/O Scheduler           | `none`                          | Recommended | Set to none |
| Free Space              | ≥ 20–25%                        | Yes       | Adjust watermarks |

---

### **Updated Verification & Fix Steps**

#### **1. Alignment & Sector Size**
**Verify:**
```bash
lsblk -d -o NAME,SIZE,TYPE
blockdev --report /dev/sdb                  # Best command
blockdev --getss /dev/sdb                   # Logical sector size (512 or 4096)
blockdev --getpbsz /dev/sdb                 # Physical sector size (should be 4096)
parted -l /dev/sdb                          # Start sector must be multiple of 2048
```

**Fix (if needed):**
```bash
# Preferred: Whole disk, no partition
sudo mkfs.xfs -f -m crc=1,reflink=1 /dev/sdb

# Or with partition (1 MiB aligned)
sudo parted -a optimal /dev/sdb mklabel gpt
sudo parted -a optimal /dev/sdb mkpart primary 2048s 100%
sudo mkfs.xfs -f /dev/sdb1
```

**Status:** Usually already good on modern vSAN.

---

#### **2. Readahead (Most Important Fix)**
**Verify:**
```bash
lsblk -o NAME,RA,MOUNTPOINT /dev/sdb
cat /sys/block/sdb/queue/read_ahead_kb     # ← Check this
```

**Expected:** `128`  
**If currently 8192 → FIX NEEDED**

**Fix:**
```bash
sudo blockdev --setra 256 /dev/sdb          # Sets 128 KiB

# Make persistent
cat <<EOF | sudo tee /etc/udev/rules.d/60-es-readahead.rules
ACTION=="add|change", KERNEL=="sd[b-z]*|nvme[0-9]n[0-9]*|vd[b-z]*", ATTR{queue/read_ahead_kb}="128"
EOF

sudo udevadm control --reload-rules && sudo udevadm trigger
```

---

#### **3. I/O Scheduler**
**Verify:**
```bash
cat /sys/block/sdb/queue/scheduler
```

**Expected:** `[none]`

**Fix:**
```bash
echo none | sudo tee /sys/block/sdb/queue/scheduler

# Persistent
cat <<EOF | sudo tee /etc/udev/rules.d/61-es-scheduler.rules
ACTION=="add|change", KERNEL=="sd[b-z]*|nvme*|vd*", ATTR{queue/scheduler}="none"
EOF
```

---

#### **4. Mount Options**
**Verify:**
```bash
mount | grep elasticsearch
cat /etc/fstab | grep data
```

**Expected output example:**
```
xfs defaults,noatime,nodiratime,inode64 0 2
```

**Fix:**
Update `/etc/fstab`:
```bash
UUID=xxxxxxxx /data/elasticsearch xfs defaults,noatime,nodiratime,inode64 0 2
```
Then:
```bash
sudo mount -o remount /data/elasticsearch
```

---

#### **5. OS Kernel Tuning**
**Verify:**
```bash
sysctl vm.swappiness vm.max_map_count
cat /sys/kernel/mm/transparent_hugepage/enabled
```

**Fix:**
```bash
cat <<EOF | sudo tee /etc/sysctl.d/99-elasticsearch.conf
vm.swappiness = 1
vm.max_map_count = 262144
EOF
sudo sysctl -p

echo never | sudo tee /sys/kernel/mm/transparent_hugepage/enabled
echo never | sudo tee /sys/kernel/mm/transparent_hugepage/defrag
```

---

#### **6. Elasticsearch Config**
**Verify:**
```bash
grep -E "path.data|watermark" /etc/elasticsearch/elasticsearch.yml
```

**Fix:**
```yaml
path.data: /data/elasticsearch
cluster.routing.allocation.disk.watermark.low: 80%
cluster.routing.allocation.disk.watermark.high: 85%
cluster.routing.allocation.disk.watermark.flood_stage: 90%
```

---

### **Final Verification Commands**
```bash
df -hT /data/elasticsearch
xfs_info /data/elasticsearch 2>/dev/null
lsblk -o NAME,RA,SCHED,MOUNTPOINT
iostat -x 1 5
```

**Priority Order:**
1. **Readahead** (biggest impact)
2. Mount options + XFS
3. Scheduler + sysctl
4. VMware PVSCSI + Thick Eager Zeroed

This updated checklist now clearly shows expected values and what indicates a fix is needed. You can use the script from the previous response together with this checklist.

**Updated Verification & Fix Bash Script**  
**Elasticsearch Data Disk Tuning Checker & Fixer** (RHEL 8+)

Save this as `es-disk-tune-check.sh` and run it with `sudo bash es-disk-tune-check.sh /dev/sdb` (replace `/dev/sdb` with your data disk).

```bash
#!/bin/bash
# Elasticsearch Data Disk Tuning Checker & Auto-Fixer
# Usage: sudo ./es-disk-tune-check.sh /dev/sdX   (e.g. /dev/sdb or /dev/sdb1)

DISK="${1:-/dev/sdb}"
MOUNT_POINT="/data/elasticsearch"

echo "=== Elasticsearch Disk Tuning Checker & Fixer ==="
echo "Target Disk : $DISK"
echo "Mount Point : $MOUNT_POINT"
echo "============================================"

# 1. Alignment & Sector Size
echo -e "\n[1] Alignment & Sector Size"
echo "Expected: Logical sector 512 or 4096, Physical >= 4096, 1MiB alignment"
blockdev --report "$DISK" 2>/dev/null || echo "blockdev --report failed"

echo "Logical sector size (bytes):"
blockdev --getss "$DISK" 2>/dev/null || echo "  (command not available)"

echo "Physical sector size (bytes):"
blockdev --getpbsz "$DISK" 2>/dev/null || echo "  (command not available)"

if command -v parted >/dev/null; then
    echo "Partition alignment check:"
    parted -s "$DISK" unit s print free | grep -E "Disk|Start|free"
else
    echo "parted not installed"
fi

# 2. Readahead (Critical)
echo -e "\n[2] Readahead (KiB)"
CURRENT_RA=$(lsblk -o NAME,RA --noheadings "$DISK" | awk '{print $2}')
echo "Current : ${CURRENT_RA} KiB"
echo "Expected: 128 KiB  (8192 is too high → will cause cache thrashing)"

if [ "${CURRENT_RA}" != "128" ]; then
    echo "→ FIX NEEDED"
    read -p "Apply fix now? (y/n): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        blockdev --setra 256 "$DISK"
        echo "Temporary set to 128 KiB"
        
        cat <<EOF > /etc/udev/rules.d/60-es-readahead.rules
ACTION=="add|change", KERNEL=="$(basename "$DISK")*|sd[b-z]*|nvme[0-9]n[0-9]*|vd[b-z]*", ATTR{queue/read_ahead_kb}="128"
EOF
        udevadm control --reload-rules && udevadm trigger
        echo "Persistent udev rule created"
    fi
else
    echo "→ OK (no fix needed)"
fi

# 3. I/O Scheduler
echo -e "\n[3] I/O Scheduler"
CURRENT_SCHED=$(cat /sys/block/"$(basename "$DISK")"/queue/scheduler 2>/dev/null | sed -E 's/.*\[(.*)\].*/\1/')
echo "Current : ${CURRENT_SCHED}"
echo "Expected: none"

if [ "${CURRENT_SCHED}" != "none" ]; then
    echo "→ FIX NEEDED"
    read -p "Apply fix now? (y/n): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo none > /sys/block/"$(basename "$DISK")"/queue/scheduler
        cat <<EOF > /etc/udev/rules.d/61-es-scheduler.rules
ACTION=="add|change", KERNEL=="$(basename "$DISK")*|sd[b-z]*|nvme*|vd*", ATTR{queue/scheduler}="none"
EOF
        echo "Scheduler set to none + udev rule created"
    fi
else
    echo "→ OK"
fi

# 4. Mount Options
echo -e "\n[4] Mount Options"
if mount | grep -q "${MOUNT_POINT}"; then
    mount | grep "${MOUNT_POINT}"
    if mount | grep "${MOUNT_POINT}" | grep -q "noatime"; then
        echo "→ noatime found → OK"
    else
        echo "→ noatime missing → FIX NEEDED (update /etc/fstab)"
    fi
else
    echo "→ Not mounted yet"
fi

# 5. Filesystem Type
echo -e "\n[5] Filesystem"
df -T "${MOUNT_POINT}" 2>/dev/null || echo "  Mount point not ready"
lsblk -f "$DISK" 2>/dev/null

echo -e "\n=== Summary ==="
echo "Run the script again after fixes."
echo "Final manual checks:"
echo "  df -hT ${MOUNT_POINT}"
echo "  xfs_info ${MOUNT_POINT} 2>/dev/null"
echo "  iostat -x 1 3"
```

### How to Use
1. Make executable: `chmod +x es-disk-tune-check.sh`
2. Run: `sudo ./es-disk-tune-check.sh /dev/sdb`
3. The script now clearly shows:
   - Current value
   - Expected value
   - Whether **FIX NEEDED**

### Key Fixes Applied in Script
- Corrected `blockdev --getssz` → `blockdev --getss` (logical sector size)
- Added safe checks with fallbacks
- Interactive "apply fix" for readahead and scheduler
- Persistent udev rules

Would you like a **non-interactive version** (auto-apply all fixes) or a version that also checks/fixes `elasticsearch.yml` and sysctl?
