# Elasticsearch Node Disk Tuning Guide

**Production-optimized disk configuration for Elasticsearch 8.x on VMware ESXi + vSAN + RHEL 8+**

---

## 📌 Primary Reference Document

> **🔥 Start Here**

**[FULL_ES_DISK_TUNING_GUIDE.md](FULL_ES_DISK_TUNING_GUIDE.md)**  
→ Complete background, detailed manual verification steps, fixes, and best practices.  
**This is the single source of truth.**

---

## Table of Contents

- [Quick Start](#quick-start)
- [Repository Contents](#repository-contents)
- [Key Optimizations](#key-optimizations)
- [Important Notes](#important-notes)
- [Additional Resources](#additional-resources)

---

## Quick Start

### 1. Safe Interactive Checker (Recommended First)

```bash
curl -O https://raw.githubusercontent.com/nwlterry/es_node_disk_tuning/main/es-disk-tune-check.sh
chmod +x es-disk-tune-check.sh
sudo ./es-disk-tune-check.sh /dev/sdb
```

### 2. Full Auto-Fix Script (with safe formatting prompt)

```bash
curl -O https://raw.githubusercontent.com/nwlterry/es_node_disk_tuning/main/es-disk-full-autofix.sh
chmod +x es-disk-full-autofix.sh

# Interactive mode (recommended)
sudo ./es-disk-full-autofix.sh /dev/sdb

# Force mode (use only if disk is empty)
sudo ./es-disk-full-autofix.sh /dev/sdb --force
```

---

## Repository Contents

| File                              | Purpose |
|-----------------------------------|-------|
| **`FULL_ES_DISK_TUNING_GUIDE.md`** | **Main comprehensive guide** – Background + Full manual steps |
| `es-disk-tune-check.sh`           | Safe interactive checker & partial fixer |
| `es-disk-full-autofix.sh`         | Full automatic tuning (with confirmation for formatting) |
| `README.md`                       | This file |

---

## Key Optimizations (Summary)

| Setting                        | Recommended Value                                      | Impact       |
|--------------------------------|--------------------------------------------------------|--------------|
| **Readahead**                  | **128 KiB**                                            | **Critical** |
| Filesystem                     | XFS (whole disk preferred)                             | High         |
| Mount Options                  | `noatime,nodiratime,inode64,logbufs=8,logbsize=256k,allocsize=64k` | High |
| I/O Scheduler                  | `none`                                                 | Medium       |
| Transparent Huge Pages         | `never` (enabled + defrag)                             | High         |
| Alignment                      | 1 MiB                                                  | Good         |
| Free Space                     | ≥ 20–25%                                               | Critical     |

---

## Important Notes

- Always run on **dedicated data disks only** (`/dev/sdb`, `/dev/sdc`, etc.).
- Backup important data before running any formatting.
- After tuning, update `elasticsearch.yml` → `path.data: /data/elasticsearch` and restart Elasticsearch.
- Monitor performance using `iostat -x`, `_nodes/stats/fs`, and search latency.

---

## Additional Resources

- **[Full Detailed Guide](FULL_ES_DISK_TUNING_GUIDE.md)**

---

**Repository maintained for standardizing high-performance Elasticsearch storage across production clusters.**

Feel free to open Issues or submit Pull Requests!
