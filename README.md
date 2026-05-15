**Elasticsearch data disk tuning and alignment recommendations** (for hot 2TB and cold 10TB nodes) on VMware ESXi 7+ / vSAN / RHEL 8+ / Elasticsearch 8.x (8.14.3+ and 8.18.4).

These guidelines follow current Elastic best practices (XFS, `noatime`, readahead tuning), RHEL 8+ storage guidance, and VMware vSAN virtual-disk performance rules. The goal is to minimize I/O latency, avoid unnecessary metadata writes, optimize random reads (critical for search), and ensure proper alignment on virtual storage.

### 1. VMware vSphere / vSAN Side (Host-Level Disk Presentation)
Before the guest sees the disk:

- **Controller**: Attach the data VMDK to a **Paravirtual SCSI (PVSCSI)** adapter (not LSI Logic). This gives the best throughput and lowest latency for Elasticsearch workloads.
- **VMDK provisioning**: Use **Thick Eager Zeroed** (not Thin or Lazy Zeroed). This eliminates first-write penalties.
- **vSAN Storage Policy** (via Storage Policy Based Management):
  - **Hot nodes (2TB)**: Prioritize performance → RAID-1 (mirroring), FTT=1 or FTT=2, Object Space Reservation = 0 (thin), Number of disk stripes per object = 1–2 (higher stripes help write parallelism if your vSAN cluster is large).
  - **Cold nodes (10TB)**: Prioritize capacity → RAID-5 or RAID-6 (erasure coding) if cluster ≥ 4–6 hosts, FTT=1 or 2.
- Keep at least 20–25 % free space on the volume (Elasticsearch disk watermarks default to 85/90/95 %; you can tighten them in `elasticsearch.yml`).
- Avoid mixing hot/cold data disks on the same vSAN datastore if possible (separate datastores or policies).

### 2. Guest OS (RHEL 8+) – Disk Alignment, Partitioning & Formatting
**Recommended approach: Use the whole disk (no partition)** when the VMDK is dedicated to Elasticsearch. This eliminates partition-table overhead and alignment concerns entirely.

**Alternative (if you prefer a partition)**: Use GPT with optimal (1 MiB / 2048-sector) alignment.

#### Whole-disk method (preferred for simplicity and performance)
```bash
# Identify the disk (example: /dev/sdb – confirm with lsblk -d)
lsblk -d -o NAME,SIZE,TYPE

# Format directly with XFS (no partition table)
sudo mkfs.xfs -f /dev/sdb
```

#### Partitioned method (if required by policy)
```bash
sudo parted -a optimal /dev/sdb mklabel gpt
sudo parted -a optimal /dev/sdb mkpart primary 2048s 100%
sudo mkfs.xfs -f /dev/sdb1
```

- `-a optimal` ensures 1 MiB alignment (standard and sufficient on modern ESXi + vSAN).
- XFS is the **strongly recommended filesystem** for Elasticsearch on RHEL 8+ (better large-file allocation, scalability on 10 TB volumes, and Elastic’s own preference in Elastic Cloud Enterprise).

### 3. Mount Options (/etc/fstab)
Use these options for the data path (example mount point `/data/elasticsearch` or `/var/lib/elasticsearch`):

```bash
# Example fstab entry (whole disk)
UUID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx /data/elasticsearch  xfs  defaults,noatime,nodiratime,inode64  0  2

# Or for partitioned disk
UUID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx /data/elasticsearch  xfs  defaults,noatime,nodiratime,inode64  0  2
```

**Key options explained**:
- `noatime,nodiratime` → Eliminates access-time metadata updates (big win for Elasticsearch’s many small segment files).
- `inode64` → Required for filesystems > ~2 TB (RHEL 8+ defaults to it on 64-bit, but explicitly adding it is safe).
- Optional performance tweaks (add if you see high logging contention): `,logbsize=256k,logbufs=8,allocsize=64k`.

After editing fstab:
```bash
sudo mkdir -p /data/elasticsearch
sudo mount -a
sudo chown -R elasticsearch:elasticsearch /data/elasticsearch
```

### 4. Block Device Tuning (Critical for Elasticsearch)
**Readahead (most important search-performance knob)**  
Elasticsearch uses `mmap` heavily for segments. High readahead causes cache thrashing on random reads.

```bash
# Check current value (in KiB)
lsblk -o NAME,RA,MOUNTPOINT

# Set to Elastic-recommended 128 KiB (256 sectors of 512 B)
sudo blockdev --setra 256 /dev/sdb     # (or /dev/sdb1 if partitioned)

# Make persistent (udev rule)
cat <<EOF | sudo tee /etc/udev/rules.d/60-readahead.rules
ACTION=="add|change", KERNEL=="sd[b-z]", ATTR{queue/read_ahead_kb}="128"
EOF
sudo udevadm control --reload-rules && sudo udevadm trigger
```

**I/O Scheduler**
On virtual disks (PVSCSI) the best is usually `none`:
```bash
echo none | sudo tee /sys/block/sdb/queue/scheduler
# Make persistent via tuned or udev
```

### 5. Additional RHEL 8+ & Elasticsearch Disk-Related Settings
Add to `/etc/sysctl.conf` (or a dedicated `.conf` in `/etc/sysctl.d/`):
```bash
vm.swappiness = 1
vm.max_map_count = 262144
```

Reload:
```bash
sudo sysctl -p
```

- Disable Transparent Huge Pages (THP) – Elastic recommendation:
  ```bash
  echo never | sudo tee /sys/kernel/mm/transparent_hugepage/enabled
  echo never | sudo tee /sys/kernel/mm/transparent_hugepage/defrag
  ```
  Make persistent via `tuned` or grub.

- Consider the `virtual-guest` or `balanced` tuned profile as a base, then override the above settings.

### 6. Elasticsearch Configuration (`elasticsearch.yml`)
```yaml
path.data: /data/elasticsearch   # ← your mounted disk
# Optional but recommended for production
index.store.type: fs             # default is fine; do not use simplefs
cluster.routing.allocation.disk.watermark.low: 80%
cluster.routing.allocation.disk.watermark.high: 85%
cluster.routing.allocation.disk.watermark.flood_stage: 90%
```

### 7. Hot vs Cold Node Differences
| Aspect              | Hot (2 TB)                  | Cold (10 TB)                     |
|---------------------|-----------------------------|----------------------------------|
| Workload            | High write + search         | Mostly read / archival           |
| vSAN policy         | RAID-1, higher stripes      | RAID-5/6 possible                |
| Readahead           | 128 KiB                     | 128 KiB (or test 256 KiB)        |
| Mount options       | Same                        | Same + `inode64` explicitly      |
| Free space target   | ≥ 25 %                      | ≥ 20 %                           |

### 8. Verification Commands
```bash
# Filesystem & mount
df -hT /data/elasticsearch
mount | grep elasticsearch
xfs_info /data/elasticsearch

# Readahead & scheduler
lsblk -o NAME,RA,MOUNTPOINT
cat /sys/block/sdb/queue/scheduler
cat /sys/block/sdb/queue/read_ahead_kb

# ES disk usage & health
curl -X GET "localhost:9200/_cat/allocation?v"
curl -X GET "localhost:9200/_cluster/health?pretty"
```

These settings are battle-tested across Elastic 8.x deployments on RHEL 8+ virtualized environments. After implementation, monitor with `_nodes/stats/fs` and `_cat/indices` for I/O wait and disk usage. If you have specific workload details (ingest rate, query pattern, or exact vSAN cluster size), further fine-tuning (e.g., stripes, translog durability) is possible. Let me know if you need the exact systemd or tuned profile snippets!
