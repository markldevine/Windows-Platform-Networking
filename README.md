This README serves as the "Source of Truth" for the **RSE Dynamic DNS Orchestrator**. It is designed to handle the complex networking requirements of WSL2 in **Mirrored Mode**, ensuring that internal Lab resources (`*.rse.local`) and external Internet/VPN resources resolve correctly without manual intervention as you move between different networks.

---

## 1. Architecture Overview

In **Mirrored Mode**, WSL2 mirrors the Windows host's networking stack. This design uses a Linux-side "Orchestrator" to identify the Lab and Internet interfaces via subnet fingerprinting and gateway tracking, then configures `systemd-resolved` to handle split-horizon DNS.

---

## 2. Windows Host Configuration

All machines (Desktops, Laptops) must have this configuration to enable the underlying networking features.

**File:** `C:\Users\<Username>\.wslconfig`

```ini
[wsl2]
# Mirrored mode makes WSL interfaces match Windows interfaces 1:1
networkingMode=mirrored
# dnsTunneling allows Windows to handle DNS resolution for corporate VPNs/Wi-Fi
dnsTunneling=true
# hostAddressLoopback allows WSL services to be reachable on your LAN via Host IP
hostAddressLoopback=true

```

*Note: Run `wsl --shutdown` in PowerShell after editing.*

---

## 3. Linux Orchestrator Implementation

### A. The Orchestrator Script

This script performs environment discovery. It identifies the Lab by the `172.19.2.x` signature and the Internet by the default route. It uses `8.8.8.8` as a "proxy target" to trigger Windows DNS Tunneling.

**Path:** `/usr/local/bin/rse-dns-orchestrator.sh`

```bash
#!/bin/bash
# ==============================================================================
# RSE DYNAMIC DNS ORCHESTRATOR
# ==============================================================================

# 1. Discovery Phase
# Find Lab by its unique subnet signature
LAB_IF=$(ip -4 -o addr show | grep "172.19.2." | awk '{print $2}' | head -n1)
# Find Internet by the active Default Gateway
INET_IF=$(ip -4 route show default | awk '{print $5}' | head -n1)

# 2. Reset Phase
# Clear previous resolve settings to prevent stale conflicts
for i in $(ls /sys/class/net | grep eth); do /usr/bin/resolvectl revert "$i"; done

# 3. Lab Mapping (rse.local)
if [ -n "$LAB_IF" ]; then
    /usr/bin/resolvectl dns "$LAB_IF" 172.19.2.100 172.19.2.101
    /usr/bin/resolvectl domain "$LAB_IF" "~rse.local"
    /usr/bin/resolvectl default-route "$LAB_IF" no
fi

# 4. Internet Mapping (Global Fallback)
if [ -n "$INET_IF" ]; then
    # Using public IPs here triggers Windows DNS Tunneling to intercept the request
    /usr/bin/resolvectl dns "$INET_IF" 8.8.8.8 1.1.1.1
    /usr/bin/resolvectl domain "$INET_IF" "~."
    /usr/bin/resolvectl default-route "$INET_IF" yes

    # Disable noise protocols that cause hangs/timeouts in corporate environments
    /usr/bin/resolvectl dnssec "$INET_IF" no
    /usr/bin/resolvectl llmnr "$INET_IF" no
    /usr/bin/resolvectl mdns "$INET_IF" no
fi

/usr/bin/resolvectl flush-caches

```

### B. The Systemd Service

This ensures the orchestrator runs automatically at every boot.

**Path:** `/etc/systemd/system/rse-dns-orchestrator.service`

```ini
[Unit]
Description=RSE Dynamic DNS Orchestrator
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/rse-dns-orchestrator.sh

[Install]
WantedBy=multi-user.target

```

---

## 4. Deployment Instructions (The "Clean Slate" Method)

Run these commands as **root** to install or overwrite existing configurations:

```bash
# 1. Set permissions
chmod +x /usr/local/bin/rse-dns-orchestrator.sh

# 2. Force systemd-resolved to manage the system DNS
ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf

# 3. Enable and trigger the Orchestrator
systemctl daemon-reload
systemctl enable --now systemd-resolved
systemctl enable --now rse-dns-orchestrator.service

```

---

## 5. Troubleshooting & Verification

### **Verification Commands**

* **Check Status:** `resolvectl status`
* *Expectation:* `~rse.local` on the Lab link, `~.` on the Internet link.


* **Internal Test:** `resolvectl query mos01.rse.local`
* *Expectation:* Instant resolution via Lab link.


* **Internet Test:** `resolvectl query www.google.com`
* *Expectation:* Instant resolution via Internet link (intercepted by Windows Tunneling).



### **Known Fixes**

* **Hang on Internet Queries:** If `www.google.com` hangs, ensure `dnsTunneling=true` is set in `.wslconfig`.
* **Lab Resolution Fails:** Ensure the Windows Host Firewall permits traffic on the `vSwitch-Dev` (set to "Private" in PowerShell).

---
