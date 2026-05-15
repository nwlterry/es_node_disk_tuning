**✅ Done!** I have prepared the **complete updated content** for your GitHub file.

### Updated Content for `followup_04.md`

Copy and paste the entire block below into your file (replace everything):

```markdown
**Updated Summary – Elasticsearch Data Disk Tuning & Alignment**  
**(VMware ESXi 7+ / vSAN / RHEL 8+ / ES 8.14.3+)**

### **Summary of Required Settings**

| Item                        | Expected Value                                      | Critical?     | Action if Wrong                  |
|-----------------------------|-----------------------------------------------------|---------------|----------------------------------|
| Filesystem                  | XFS                                                 | Yes           | Reformat                         |
| Alignment                   | 1 MiB (2048 sectors)                                | No            | Use `parted -a optimal`          |
| Readahead                   | **128 KiB**                                         | **Yes**       | Change from 8192                 |
| Mount Options               | `defaults,noatime,nodiratime,inode64,logbufs=8,logbsize=256k,allocsize=64k` | Yes | Update fstab                     |
| I/O Scheduler               | `none`                                              | Recommended   | Set to none                      |
| Transparent Huge Pages      | `never` (both enabled + defrag)                     | Yes           | Set to never                     |
| Free Space                  | ≥ 20–25%                                            | Yes           | Adjust watermarks                |

---

### **Updated Verification & Fix Steps**

#### **1. Alignment & Sector Size + Formatting (High Risk – Confirmation Required)**
**Verify:**
```bash
blockdev --report /dev/sdb
blockdev --getss /dev/sdb
blockdev --getpbsz /dev/sdb
parted -l /dev/sdb
```

**Fix (with strong confirmation):**
```bash
# WARNING: This will ERASE ALL DATA on the disk!
echo "WARNING: Formatting will destroy all data on $DISK"
read -p "Type CONFIRM-FORMAT to proceed: " confirm
if [[ "$confirm" == "CONFIRM-FORMAT" ]]; then
    # Preferred: Whole disk, no partition
    sudo mkfs.xfs -f -m crc=1,reflink=1 /dev/sdb
else
    echo "Formatting cancelled."
fi
```

---

#### **2. Readahead (Most Important Fix)**
**Verify:**
```bash
lsblk -o NAME,RA,MOUNTPOINT /dev/sdb
cat /sys/block/sdb/queue/read_ahead_kb
```

**Expected:** `128`  
**If currently 8192 → FIX NEEDED**

**Fix:**
```bash
sudo blockdev --setra 256 /dev/sdb

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

#### **4. Mount Options (with XFS Tuning)**
**Verify:**
```bash
mount | grep elasticsearch
cat /etc/fstab | grep data
```

**Expected:**
```
xfs defaults,noatime,nodiratime,inode64,logbufs=8,logbsize=256k,allocsize=64k 0 2
```

**Fix:**
Update `/etc/fstab` with the line above, then:
```bash
sudo mount -o remount /data/elasticsearch
```

---

#### **5. Transparent Huge Pages (enabled + defrag)**
**Verify:**
```bash
cat /sys/kernel/mm/transparent_hugepage/enabled
cat /sys/kernel/mm/transparent_hugepage/defrag
```

**Expected:** Both show `[never]`

**Fix:**
```bash
echo never | sudo tee /sys/kernel/mm/transparent_hugepage/enabled
echo never | sudo tee /sys/kernel/mm/transparent_hugepage/defrag

# Persistent systemd service
cat <<EOF | sudo tee /etc/systemd/system/disable-thp.service
[Unit]
Description=Disable Transparent Huge Pages
After=sysinit.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'echo never > /sys/kernel/mm/transparent_hugepage/enabled'
ExecStart=/bin/sh -c 'echo never > /sys/kernel/mm/transparent_hugepage/defrag'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now disable-thp.service
```

---

#### **6. OS Kernel Tuning & Elasticsearch Config**
**Verify:**
```bash
sysctl vm.swappiness vm.max_map_count
grep -E "path.data|watermark" /etc/elasticsearch/elasticsearch.yml
```

**Fix:**
```bash
# /etc/sysctl.d/99-elasticsearch.conf
vm.swappiness = 1
vm.max_map_count = 262144
```

```yaml
# elasticsearch.yml
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
1. Readahead  
2. Mount options + XFS  
3. THP + Scheduler  
4. Formatting (only if needed)

---

### **Updated Bash Script** (`es-disk-tune-check.sh`)

```bash
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
    if [[ $REPLY =~ ^[Yy]$ ]]; then
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
SCHED=$(cat /sys/block/"$(basename "$DISK")"/queue/scheduler 2>/dev/null | sed -E 's/.*\[(.*)\].*/\1/')
echo "Current : $SCHED (Expected: none)"
if [ "$SCHED" != "none" ]; then
    echo "→ FIX NEEDED"
    read -p "Apply scheduler fix? (y/n): " -n 1 -r
    if [[ $REPLY =~ ^[Yy]$ ]]; then
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
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo never > /sys/kernel/mm/transparent_hugepage/enabled
        echo never > /sys/kernel/mm/transparent_hugepage/defrag
        echo "→ Applied (temporary)"
    fi
else
    echo "→ OK"
fi

echo -e "\n=== Summary ==="
echo "Run the script again after fixes."
```

---

**How to update your repo:**

1. Go to: https://github.com/nwlterry/es_node_disk_tuning/blob/main/followup_04.md
2. Click **Edit** (pencil icon)
3. Replace the whole content with the above
4. Commit with message: `Update followup_04.md with latest tuning (XFS options + THP + formatting confirmation)`

Would you like me to also create a clean `README.md` or a non-interactive full auto-fix script for the repo?
