# Elasticsearch Node Disk Tuning Guide

**Production-optimized disk configuration for Elasticsearch 8.x on VMware ESXi + vSAN + RHEL 8+**

---

## 📌 Primary Reference Document

> **🔥 Recommended Starting Point**

**[FULL_ES_DISK_TUNING_GUIDE.md](FULL_ES_DISK_TUNING_GUIDE.md)**  
→ Complete background, detailed manual verification steps, fixes, and best practices.

This is the **single source of truth** compiled from all previous discussions.

---

## 🎯 Quick Start

### 1. Safe Interactive Checker (Recommended)

```bash
curl -O https://raw.githubusercontent.com/nwlterry/es_node_disk_tuning/main/es-disk-tune-check.sh
chmod +x es-disk-tune-check.sh
sudo ./es-disk-tune-check.sh /dev/sdb
```

### 2. Full Auto-Fix Script (with safe formatting prompt)

```bash
curl -O https://raw.githubusercontent.com/nwlterry/es_node_disk_tuning/main/es-disk-full-autofix.sh
chmod +x es-disk-full-autofix.sh

# Interactive (recommended)
sudo ./es-disk-full-autofix.sh /dev/sdb

# Force mode (only if you know what you're doing)
sudo ./es-disk-full-autofix.sh /dev/sdb --force
```

---

## 📂 Repository Contents

| File                              | Purpose |
|-----------------------------------|-------|
| **`FULL_ES_DISK_TUNING_GUIDE.md`** | **Main comprehensive guide** – Background + Full manual steps |
| `es-disk-tune-check.sh`           | Safe interactive checker & partial fixer |
| `es-disk-full-autofix.sh`         | Full automatic tuning (with confirmation for formatting) |
| `followup_04.md`                  | Original conversation history |
| `README.md`                       | This file |

---

## 🎯 Key Optimizations (Summary)

- **Readahead**: 128 KiB (most critical)
- **Filesystem**: XFS with optimized parameters
- **Mount Options**: `noatime,nodiratime,inode64,logbufs=8,logbsize=256k,allocsize=64k`
- **I/O Scheduler**: `none`
- **Transparent Huge Pages**: Disabled (`never`)
- **Alignment**: 1 MiB
- **Free Space**: Minimum 20–25%

---

## ⚠️ Important Notes

- Always run on **dedicated data disks** only (`/dev/sdb`, `/dev/sdc`, etc.).
- Backup data before formatting.
- After tuning, update `elasticsearch.yml` with correct `path.data` and restart Elasticsearch.
- Monitor with `iostat`, `_nodes/stats/fs`, and search latency after changes.

---

## 📖 Additional Resources

- [Full Detailed Guide](FULL_ES_DISK_TUNING_GUIDE.md)
- [Conversation History](followup_04.md)

---

**Repository maintained for standardizing high-performance Elasticsearch storage across production clusters.**

Feel free to open Issues or submit Pull Requests!
