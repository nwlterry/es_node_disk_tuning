**Yes — change it.** Even if `blockdev` currently shows **8192** (8 MiB), you should lower it.

### Why Lower from 8192?
Elastic’s official recommendation (still current in 8.14+ / 8.18.x) is **128 KiB** readahead for all Elasticsearch data disks.

- High readahead (several MiB) is very common on vSAN / LVM / multipath / virtual disks.
- Elasticsearch uses `mmap` heavily for Lucene segments → high readahead causes massive unnecessary page-cache reads (cache thrashing), hurting search latency and throughput.
- 8192 KiB is **excessive** for random-read-heavy workloads like search.

**Action** (safe to do live):

```bash
# Temporarily set to recommended 128 KiB
sudo blockdev --setra 256 /dev/sdb     # (or /dev/sdb1)

# Verify
lsblk -o NAME,RA,MOUNTPOINT
```

**Make it persistent** (recommended udev rule):

```bash
cat <<EOF | sudo tee /etc/udev/rules.d/60-elasticsearch-readahead.rules
ACTION=="add|change", KERNEL=="sd[b-z]*|nvme[0-9]n[0-9]*|vd[b-z]*", ATTR{queue/read_ahead_kb}="128"
EOF

sudo udevadm control --reload-rules
sudo udevadm trigger
```

> **Note**: `blockdev --setra 256` = 128 KiB (because `blockdev` uses 512-byte sectors, `lsblk` shows KiB).

You can test 256 KiB (128 KiB) vs 512 KiB (256 KiB) on your workload — most people stay at 128 KiB.

### Do You Need 4K Alignment?
**Short answer**: No special action needed in most cases — you are already well-aligned.

**Details**:
- Modern VMware ESXi 7+ + vSAN + PVSCSI + XFS already uses **1 MiB alignment** by default (2048 sectors of 512 B = 1 MiB).
- This is more than enough for 4K (4096-byte) native or emulated sectors.
- SSDs/NVMe (and vSAN objects) internally optimize for 4K or multiples of it. 1 MiB alignment is excellent.

**How to confirm your current alignment**:

```bash
# For whole disk (no partition)
sudo blockdev --getpbsz /dev/sdb          # physical sector size
sudo blockdev --getssz /dev/sdb           # logical sector size

# If partitioned
sudo parted -l /dev/sdb
# Look at "Start" sector — should be multiple of 2048 (1 MiB)
```

If you ever recreate the filesystem/partition:
- Use `parted -a optimal` (as I showed previously) → guarantees 1 MiB alignment.
- Or `mkfs.xfs -f -m crc=1,reflink=1,align=1 /dev/sdb`

**Bottom line**: Your current setup is fine regarding alignment. Focus on dropping the readahead from 8192 → 128.

After changing readahead, monitor for a day or two:
- Search latency / throughput
- `iostat -x 1` (see `%util`, `await`, `r/s`)
- Elasticsearch `_nodes/stats/fs?pretty`

Would you like me to give you the full tuned profile snippet or a small script to apply these settings across multiple nodes?
