# Firmware Build System Guide

This module covers the tools and processes used to modify the Root Filesystem (RootFS) and generate recovery bundles for TP-Link Archer routers (BE220, BE230, BE3500, BE3600).

## Overview

The build system is designed to take a standard firmware image or a raw RootFS, apply specific patches to bypass manufacturer restrictions, and repack it into a usable format. This is critical for achieving persistent root access and SSH functionality.

## Key Components

### 1. RootFS Modification (`build_rootfs.sh`)
The `build_rootfs.sh` script is the primary tool for customizing the operating system's filesystem.

**Workflow:**
1. **Unpacking**: The script extracts the existing SquashFS image into a working directory (often `squashfs-root/`).
2. **Patching**: It applies several critical modifications:
    * **Dropbear SSH Fix**: Modifies Dropbear configuration to bypass session restrictions imposed by the manufacturer.
    * **PTY Permissions**: Corrects `/dev/pts` permissions to ensure terminal access works correctly after reboot.
    * **Custom Initialization**: Adds scripts to `/etc/rc.d/` to ensure custom configurations are applied during boot.
3. **Repacking**: The modified filesystem is compressed back into a SquashFS image.

### 2. Recovery Bundle Generation (`generate_recovery_bundle.sh`)
This script automates the creation of a Broadcom BCA FIT (Flattened Image Tree) bundle. This bundle is used in "Rescue Mode" to recover or update the device via the WPS Web UI.

**Workflow:**
1. **Image Preparation**: Combines kernel, rootfs, and configuration data into a single structure.
2. **FIT Creation**: Uses `mkimage` tools to create a FIT image defined by the `firmware.its` template.
3. **Bundle Packaging**: Packages the FIT image into a format recognized by the router's recovery mechanism.

### 3. Image Templates (`firmware.its`)
The `firmware.its` file is a Device Tree Source (DTS) template used by the build tools to define the structure and metadata of the final firmware image. It ensures that the resulting binary is correctly interpreted by the Broadcom bootloader.

## Troubleshooting & Best Practices

* **Verify SquashFS**: Always ensure the `squashfs-root/` directory is clean before starting a new build to avoid leftover artifacts from previous runs.
* **Checksum Validation**: After repacking, verify the integrity of the generated image using standard checksum tools.
* **Log Inspection**: Monitor the output of `build_rootfs.sh` closely for any errors during the patching phase, especially regarding file permissions or missing directories.
