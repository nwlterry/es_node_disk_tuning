# Full Elasticsearch Data Disk Tuning Guide  
**Complete Background + Manual Step-by-Step Verification & Fix**

**Platform**: VMware ESXi 7+ | vSAN | RHEL 8+ | Elasticsearch 8.x (8.14.3+ / 8.18.4)  
**Disks**: 2 TB (hot) / 10 TB (cold) dedicated data VMDKs

This is the **single source of truth** compiled from `information.md` + all four followup documents. It contains full background, current best practices, and detailed manual checking/verification/fix steps.

---

## 🎯 Background & Why This Tuning Matters

Elasticsearch is extremely I/O sensitive, especially for search workloads that rely heavily on `mmap` for Lucene segment files. On VMware vSAN + PVSCSI, default settings often cause:

- Excessive readahead (8192 KiB or higher) → page-cache thrashing
- Unnecessary metadata updates (`atime`)
- Sub-optimal XFS parameters on large volumes
- Transparent Huge Pages (THP) causing latency spikes
- Misaligned I/O or poor provisioning

**Goals**:
- Minimize latency on random reads
- Reduce unnecessary disk writes
- Ensure 1 MiB alignment
- Make settings persistent across reboots
- Differentiate hot vs cold nodes

These recommendations follow Elastic official guidance, RHEL 8+ storage best practices, and real-world production experience on vSAN.

---

## 📋 Summary of Required Settings

| Item                        | Expected Value                                      | Critical?     | Action if Wrong                  |
|-----------------------------|-----------------------------------------------------|---------------|----------------------------------|
| Filesystem                  | XFS (whole disk preferred)                          | Yes           | Reformat                         |
| Alignment                   | 1 MiB (2048 sectors)                                | No            | Use `parted -a optimal`          |
| Readahead                   | **128 KiB**                                         | **Yes**       | Change from 8192                 |
| Mount Options               | `defaults,noatime,nodiratime,inode64,logbufs=8,logbsize=256k,allocsize=64k` | Yes | Update fstab                     |
| I/O Scheduler               | `none`                                              | Recommended   | Set to none                      |
| Transparent Huge Pages      | `never` (both enabled + defrag)                     | Yes           | Set to never                     |
| Free Space                  | ≥ 20–25%                                            | Yes           | Adjust watermarks                |

---

## 🔧 Step-by-Step Manual Checking, Verification & Fix

### 1. VMware vSphere / vSAN Side (Host-Level)
**Verify:**
- VMDK attached to **Paravirtual SCSI (PVSCSI)** controller
- Provisioned as **Thick Eager Zeroed**
- Correct Storage Policy (RAID-1 for Hot, RAID-5/6 for Cold)

**Fix:**
- Edit VM → Hardware → Change to Paravirtual SCSI
- Storage vMotion with new policy if needed

---

### 2. Alignment & Sector Size + Formatting (High Risk)
**Verify:**
```bash
blockdev --report /dev/sdb
blockdev --getss /dev/sdb          # Logical
blockdev --getpbsz /dev/sdb        # Physical (should be 4096)
parted -l /dev/sdb
lsblk -d -o NAME,SIZE,TYPE
```

**Fix (with confirmation):**
```bash
# WARNING: Destructive!
echo "WARNING: This will ERASE ALL DATA on $DISK"
read -p "Type CONFIRM-FORMAT to proceed: " confirm
if [[ "$confirm" == "CONFIRM-FORMAT" ]]; then
    sudo mkfs.xfs -f -m crc=1,reflink=1 /dev/sdb     # Preferred: whole disk
else
    echo "Formatting cancelled."
fi
```

**Alternative (partitioned):**
```bash
sudo parted -a optimal /dev/sdb mklabel gpt
sudo parted -a optimal /dev/sdb mkpart primary 2048s 100%
sudo mkfs.xfs -f /dev/sdb1
```

---

### 3. Mount Options (XFS Optimized)
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
```bash
# Update /etc/fstab
UUID=xxxxxxxx /data/elasticsearch xfs defaults,noatime,nodiratime,inode64,logbufs=8,logbsize=256k,allocsize=64k 0 2
sudo mount -o remount /data/elasticsearch
sudo chown -R elasticsearch:elasticsearch /data/elasticsearch
```

---

### 4. Readahead (Most Critical Fix)
**Verify:**
```bash
lsblk -o NAME,RA,MOUNTPOINT /dev/sdb
cat /sys/block/sdb/queue/read_ahead_kb
```

**Expected:** `128`  
**If 8192 (or higher) → FIX NEEDED**

**Fix:**
```bash
sudo blockdev --setra 256 /dev/sdb

# Persistent udev rule
cat <<EOF | sudo tee /etc/udev/rules.d/60-es-readahead.rules
ACTION=="add|change", KERNEL=="sd[b-z]*|nvme[0-9]n[0-9]*|vd[b-z]*", ATTR{queue/read_ahead_kb}="128"
EOF
sudo udevadm control --reload-rules && sudo udevadm trigger
```

---

### 5. I/O Scheduler
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

### 6. Transparent Huge Pages (THP)
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

sudo systemctl daemon-reload
sudo systemctl enable --now disable-thp.service
```

---

### 7. OS Kernel & Elasticsearch Config
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
sudo sysctl -p

# elasticsearch.yml
path.data: /data/elasticsearch
cluster.routing.allocation.disk.watermark.low: 80%
cluster.routing.allocation.disk.watermark.high: 85%
cluster.routing.allocation.disk.watermark.flood_stage: 90%
```

---

### 8. Final Verification Commands
```bash
df -hT /data/elasticsearch
xfs_info /data/elasticsearch
lsblk -o NAME,RA,SCHED,MOUNTPOINT
iostat -x 1 5
curl localhost:9200/_cat/allocation?v
curl localhost:9200/_nodes/stats/fs?pretty
```

---

## 📂 Related Files in Repository
- `es-disk-tune-check.sh` → Safe interactive checker
- `es-disk-full-autofix.sh` → Full auto-fix (with confirmation)
- `README.md` → Quick start

**Priority Order to Apply:**
1. Readahead
2. Mount options + XFS formatting (if needed)
3. THP + Scheduler
4. VMware side + Elasticsearch config

After changes, monitor search latency and `_nodes/stats/fs` for 24–48 hours.

---

**This guide is maintained for production Elasticsearch clusters.**  
Last updated: May 2026
```
