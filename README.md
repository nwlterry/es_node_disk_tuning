# Elasticsearch Node Disk Tuning Guide

**Optimized disk configuration for Elasticsearch 8.x on VMware ESXi + vSAN + RHEL 8+**

This repository contains battle-tested configurations for Elasticsearch data disks (hot & cold nodes) to achieve maximum performance, stability, and best practices.

---

## 🎯 Key Optimizations Included

| Setting                     | Recommended Value                            | Impact                  |
|----------------------------|----------------------------------------------|-------------------------|
| Filesystem                 | XFS (whole disk preferred)                   | High                    |
| Alignment                  | 1 MiB                                        | Good                    |
| Readahead                  | **128 KiB** (critical)                       | **Very High**           |
| Mount Options              | `noatime,nodiratime,inode64,logbufs=8,logbsize=256k,allocsize=64k` | High |
| I/O Scheduler              | `none`                                       | Medium                  |
| Transparent Huge Pages     | `never` (enabled + defrag)                   | High                    |
| Free Space                 | ≥ 20–25%                                     | Critical                |

---

## 📋 Quick Start

### 1. Run the Checker Script (Recommended)

```bash
# Download
curl -O https://raw.githubusercontent.com/nwlterry/es_node_disk_tuning/main/es-disk-tune-check.sh

# Make executable and run
chmod +x es-disk-tune-check.sh
sudo ./es-disk-tune-check.sh /dev/sdb
