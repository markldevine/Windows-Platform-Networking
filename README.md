---

# RSE Dynamic DNS Orchestrator: Implementation Guide

This guide provides a "set-and-forget" networking architecture for WSL2 (OpenSUSE Tumbleweed) that enables seamless **Split-DNS**. It ensures internal lab resources (`*.rse.local`) resolve via your private Hyper-V switch, while all other internet and corporate VPN traffic routes dynamically through the Windows host.

---

## 1. Phase 1: Windows Host Standardization (Run Once)

The Windows 11 host must be standardized to support **Mirrored Mode** and proper **Metric Priority**. This prevents Windows from getting "confused" between your Lab and your Wi-Fi.

### A. Host Configuration (`.wslconfig`)

Ensure your `%USERPROFILE%\.wslconfig` (e.g., `C:\Users\Mark\.wslconfig`) contains these settings:

```ini
[wsl2]
# Mirrored mode makes WSL interfaces match Windows interfaces 1:1
networkingMode=mirrored
# dnsTunneling allows Windows to handle DNS for corporate VPNs/Wi-Fi
dnsTunneling=true
# hostAddressLoopback allows LAN access to WSL services via Host IP
hostAddressLoopback=true

```

> **Action:** After saving, run `wsl --shutdown` in an Administrator PowerShell.

### B. Route & Interface Metrics (PowerShell Admin)

Run these commands to ensure the Internet always has priority over the Lab for general traffic.

```powershell
# 1. Set Wi-Fi to high priority (Metric 10)
Set-NetIPInterface -InterfaceAlias "Wi-Fi" -InterfaceMetric 10

# 2. Set Lab Switch to low priority (Metric 500)
# This prevents Windows from ever trying to use the Lab for general internet.
Set-NetIPInterface -InterfaceAlias "vEthernet (vSwitch-Dev)" -InterfaceMetric 500

# 3. Set Lab to 'Private' to ensure the Windows Firewall permits DNS traffic
$Profile = Get-NetConnectionProfile -InterfaceAlias "vEthernet (vSwitch-Dev)"
Set-NetConnectionProfile -InterfaceIndex $Profile.InterfaceIndex -NetworkCategory Private

```

---

## 2. Phase 2: Linux Orchestrator Implementation

The orchestrator uses **Subnet Fingerprinting** to find the Lab regardless of interface index shuffling (`eth0`, `eth1`, etc.).

### A. The Orchestrator Script

**Path:** `/usr/local/bin/rse-dns-orchestrator.sh`

```bash
#!/bin/bash
# ==============================================================================
# RSE DYNAMIC DNS ORCHESTRATOR - v2.1
# ==============================================================================

# 1. Discovery Phase
# Identify Lab by unique subnet (172.19.2.x) and Internet by Default Gateway
LAB_IF=$(ip -4 -o addr show | grep "172.19.2." | awk '{print $2}' | head -n1)
INET_IF=$(ip -4 route show default | awk '{print $5}' | head -n1)
INET_GW=$(ip -4 route show default | awk '{print $3}' | head -n1)

# 2. Reset Phase
# Clear stale settings from all virtual interfaces to prevent conflicts
for i in $(ls /sys/class/net | grep eth); do /usr/bin/resolvectl revert "$i"; done

# 3. Lab Mapping (rse.local)
if [ -n "$LAB_IF" ]; then
    /usr/bin/resolvectl dns "$LAB_IF" 172.19.2.100 172.19.2.101
    /usr/bin/resolvectl domain "$LAB_IF" "~rse.local"
    /usr/bin/resolvectl default-route "$LAB_IF" no
    echo "Lab mapped to $LAB_IF"
fi

# 4. Internet Mapping (Global Fallback)
if [ -n "$INET_IF" ]; then
    # Pointing to 8.8.8.8 triggers the Windows DNS Tunneling driver 
    # to intercept the port 53 traffic and resolve via the Host stack.
    /usr/bin/resolvectl dns "$INET_IF" 8.8.8.8 1.1.1.1
    /usr/bin/resolvectl domain "$INET_IF" "~."
    /usr/bin/resolvectl default-route "$INET_IF" yes

    # Disable noise protocols that cause timeout hangs in corporate environments
    /usr/bin/resolvectl dnssec "$INET_IF" no
    /usr/bin/resolvectl llmnr "$INET_IF" no
    /usr/bin/resolvectl mdns "$INET_IF" no
    echo "Internet mapped to $INET_IF via $INET_GW"
fi

/usr/bin/resolvectl flush-caches

```

### B. The Systemd Service

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

## 3. Global Linux Installation (The "Clean Slate" Block)

Execute this block as **root** in your WSL instance to clean up old configurations and deploy the Orchestrator.

```bash
# 1. Cleanup old service if it exists
systemctl disable --now rse-split-dns.service 2>/dev/null || true
rm -f /etc/systemd/system/rse-split-dns.service

# 2. Set Permissions and Link Resolver
# Using the systemd-resolved stub-resolver is required for split-DNS
chmod +x /usr/local/bin/rse-dns-orchestrator.sh
ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf

# 3. Enable and Trigger
systemctl daemon-reload
systemctl enable --now systemd-resolved
systemctl enable --now rse-dns-orchestrator.service

```

---

## 4. Verification & Testing

| Target | Command | Expected Result |
| --- | --- | --- |
| **Routing Status** | `resolvectl status` | `~rse.local` on Lab Link; `~.` on Internet Link |
| **Internal Lab** | `resolvectl query mos01.rse.local` | Resolves via 172.19.2.x (~1.5ms) |
| **Global Internet** | `resolvectl query www.ibm.com` | Resolves instantly (via Windows Tunnel) |

---

## 5. Roaming & VPN Automation (Optional)

To ensure this script re-runs automatically when your laptop wakes from sleep or you connect a VPN, add a **NetworkManager dispatcher** or a **Udev rule**.

**Recommended Udev Rule:** `/etc/udev/rules.d/99-rse-dns.rules`

```text
SUBSYSTEM=="net", ACTION=="add", RUN+="/usr/local/bin/rse-dns-orchestrator.sh"
SUBSYSTEM=="net", ACTION=="change", RUN+="/usr/local/bin/rse-dns-orchestrator.sh"

```

---

**Next Step:** This architecture is now complete and optimized for your 2025 environment. Would you like me to generate a simple "Health Check" alias you can add to your `.bashrc` to quickly see the status of your DNS links?
