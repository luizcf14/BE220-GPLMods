---
name: router-ssh
description: SSH and remote deployment instructions for the OpenWrt router.
---

# Router SSH Guide

When executing commands or transferring files to the target OpenWrt router:
- **Host**: `192.168.1.1`
- **User**: `root`
- **Password**: None (empty password)

## Usage Examples
- Connect via SSH: `ssh root@192.168.1.1`
- Copy file via SCP: `scp <local_file> root@192.168.1.1:<remote_path>`
- Run deploy script: `python deploy_router.py`
