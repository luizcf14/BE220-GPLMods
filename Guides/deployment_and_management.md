# Deployment & Management Guide

This module documents the systems used to deploy configurations, manage devices remotely via a cloud controller, and implement captive portal functionality.

## Overview

Once the customized firmware is running on the device, management and deployment are handled through a combination of web-based controllers, automated scripts, and specialized agents. This allows for remote administration, device adoption into a central system, and controlled network access.

## Key Components

### 1. Cloud Controller (`cloudController/`)
The Cloud Controller acts as the centralized management plane for all deployed devices. It allows administrators to monitor and manage multiple routers from a single interface.

* **Management Server**: A PHP-based backend that handles device communication, status reporting, and configuration updates.
* **Device Adoption**: Uses `adopted_devices.json` to track which devices are currently managed by the controller.
* **Web Interface**: A modern web UI (HTML/JS) for administrators to interact with the fleet of routers.

### 2. Captive Portal (`captivePortal/`)
The captive portal implementation provides a controlled entry point for users connecting to the network, often used for authentication or displaying landing pages.

* **Authentication Flow**: Manages how users are redirected and authenticated before gaining full network access.
* **Integration**: Works in tandem with the router's networking stack to intercept traffic and redirect it to the portal interface.

### 3. Web Deployment Agents (`web_deploy/`)
The `web_deploy/` directory contains various JavaScript-based agents and scripts used to push web configurations or monitoring tools to the devices.

* **Agent Communication**: Specialized JS files (e.g., `floresta_agent.lua`, `index-captivePortal.js`) that facilitate communication between the management plane and the device's web server.
* **Configuration Updates**: Allows for dynamic updates to the web interface on the router without requiring a full firmware reboot.

### 4. Automation & Deployment Scripts
A collection of scripts designed to automate the application of changes to live devices.

* **`deploy_be220.sh` / `deploy_cloud_run.sh`**: Automates the process of pushing new configurations or software components to specific router models.
* **`apply_to_router.py`**: A Python utility for interacting with the router's API or filesystem to apply changes remotely.

## Workflow Summary

1. **Configuration Change**: An administrator modifies a setting in the Cloud Controller or via a deployment script.
2. **Deployment Trigger**: The chosen deployment tool (e.g., `deploy_be220.sh`) initiates the transfer of new configuration files or agents.
3. **Device Application**: The router receives the update and applies it, often using a web-based agent to ensure the change is reflected in the running state without a reboot.

## Security Considerations

* **Remote Access**: Since these tools allow remote modification of the device, ensuring the security of the communication channel (e.g., via SSH or HTTPS) is paramount.
* **Agent Integrity**: Deployment agents should be verified to prevent unauthorized configuration changes.
