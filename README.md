# Elasticsearch Node Disk Tuning Guide

**Production-ready disk optimization for Elasticsearch 8.x**  
**Platform**: VMware ESXi 7+ | vSAN | RHEL 8+ | Elasticsearch 8.14.3+

---

## 🎯 Optimized Settings Summary

| Setting                        | Recommended Value                                      | Impact       |
|--------------------------------|--------------------------------------------------------|--------------|
| Filesystem                     | XFS (whole disk preferred)                             | High         |
| Alignment                      | 1 MiB                                                  | Good         |
| **Readahead**                  | **128 KiB**                                            | **Critical** |
| Mount Options                  | `noatime,nodiratime,inode64,logbufs=8,logbsize=256k,allocsize=64k` | High |
| I/O Scheduler                  | `none`                                                 | Medium       |
| Transparent Huge Pages         | `never` (enabled + defrag)                             | High         |
| Free Space                     | ≥ 20–25%                                               | Critical     |

---

## 📥 Quick Start

### Option 1: Safe Interactive Checker (Recommended First)

```bash
curl -O https://raw.githubusercontent.com/nwlterry/es_node_disk_tuning/main/es-disk-tune-check.sh
chmod +x es-disk-tune-check.sh
sudo ./es-disk-tune-check.sh /dev/sdb
