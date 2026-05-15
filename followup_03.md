**Elasticsearch Data Disk Tuning & Alignment – Summary Checklist**  
**(VMware ESXi 7+ / vSAN / RHEL 8+ / ES 8.14.3+)**

### **Summary of Required Settings**
- **Filesystem**: XFS (whole disk preferred)
- **Alignment**: 1 MiB (optimal) – already sufficient in most cases
- **Readahead**: **128 KiB** (must change if currently 8192)
- **Mount options**: `noatime,nodiratime,inode64`
- **I/O Scheduler**: `none`
- **Free space**: ≥ 20-25%

---

### **1. VMware vSAN / vSphere Side**
**Verify:**
- VMDK attached to **PVSCSI** controller
- Provisioned as **Thick Eager Zeroed**
- Correct Storage Policy (RAID-1 for Hot, RAID-5/6 for Cold)

**Fix:**
- Edit VM settings → Change adapter to Paravirtual SCSI
- If needed, Storage vMotion with new policy

---

### **2. Disk Partitioning & Filesystem (Alignment)**
**Verify:**
```bash
lsblk -d -o NAME,SIZE,TYPE
parted -l /dev/sdb
blockdev --getpbsz /dev/sdb     # Should be 4096
blockdev --getssz /dev/sdb      # Should be 512 or 4096
```

**Fix (Preferred – Whole Disk, No Partition):**
```bash
sudo mkfs.xfs -f -m crc=1,reflink=1 /dev/sdb
```

**Fix (If Partition Required):**
```bash
sudo parted -a optimal /dev/sdb mklabel gpt
sudo parted -a optimal /dev/sdb mkpart primary 2048s 100%
sudo mkfs.xfs -f /dev/sdb1
```

---

### **3. Mount Options**
**Verify:**
```bash
mount | grep elasticsearch
cat /etc/fstab | grep data
```

**Fix:**
```bash
# Example fstab entry
UUID=xxxx /data/elasticsearch xfs defaults,noatime,nodiratime,inode64 0 2
```
```bash
sudo mkdir -p /data/elasticsearch
sudo mount -a
sudo chown -R elasticsearch:elasticsearch /data/elasticsearch
```

---

### **4. Readahead (Critical – Fix if 8192)**
**Verify:**
```bash
lsblk -o NAME,RA,MOUNTPOINT
cat /sys/block/sdb/queue/read_ahead_kb     # ← Currently 8192?
```

**Fix (Set to 128 KiB):**
```bash
sudo blockdev --setra 256 /dev/sdb        # 128 KiB

# Make persistent
cat <<EOF | sudo tee /etc/udev/rules.d/60-es-readahead.rules
ACTION=="add|change", KERNEL=="sd[b-z]*|nvme[0-9]n[0-9]*|vd[b-z]*", ATTR{queue/read_ahead_kb}="128"
EOF

sudo udevadm control --reload-rules && sudo udevadm trigger
```

---

### **5. I/O Scheduler**
**Verify:**
```bash
cat /sys/block/sdb/queue/scheduler
```

**Fix:**
```bash
echo none | sudo tee /sys/block/sdb/queue/scheduler

# Persistent (create file)
cat <<EOF | sudo tee /etc/udev/rules.d/61-es-scheduler.rules
ACTION=="add|change", KERNEL=="sd[b-z]*|nvme*|vd*", ATTR{queue/scheduler}="none"
EOF
```

---

### **6. OS Kernel & System Tuning**
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

# Disable THP
echo never | sudo tee /sys/kernel/mm/transparent_hugepage/enabled
echo never | sudo tee /sys/kernel/mm/transparent_hugepage/defrag
```

---

### **7. Elasticsearch Configuration**
**Verify:**
```bash
grep -E "path.data|disk.watermark" /etc/elasticsearch/elasticsearch.yml
```

**Fix (in elasticsearch.yml):**
```yaml
path.data: /data/elasticsearch
cluster.routing.allocation.disk.watermark.low: 80%
cluster.routing.allocation.disk.watermark.high: 85%
cluster.routing.allocation.disk.watermark.flood_stage: 90%
```

Then restart Elasticsearch.

---

### **Final Verification Commands (Run After All Fixes)**
```bash
# Disk & FS
df -hT /data/elasticsearch
xfs_info /data/elasticsearch
lsblk -o NAME,RA,SCHED,MOUNTPOINT

# Performance
iostat -x 1 5
vmstat 1 5

# Elasticsearch
curl localhost:9200/_cat/allocation?v
curl localhost:9200/_nodes/stats/fs?pretty | grep -E "disk|path"
```

---

**Priority Order to Apply:**
1. Readahead (biggest impact)
2. Mount options + XFS
3. VMware PVSCSI + Thick Eager
4. Scheduler + sysctl

Would you like me to provide a single **bash script** that applies all guest OS fixes automatically?