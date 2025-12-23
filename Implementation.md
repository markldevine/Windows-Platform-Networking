### RSE Dynamic DNS Orchestrator: Implementation Guide

This guide provides a "set-and-forget" networking architecture for WSL2 (OpenSUSE Tumbleweed) that enables seamless **Split-DNS**. It ensures internal lab resources (`*.rse.local`) resolve via your private Hyper-V switch, while all other internet and corporate VPN traffic routes dynamically through Windows.

---

## 1. Windows Host Standardization (Run Once)

Before configuring Linux, the Windows 11 host must be standardized to support **Mirrored Mode** and proper **Metric Priority**.

### A. Host Configuration (`.wslconfig`)

Ensure `%USERPROFILE%\.wslconfig` contains the following settings:

```ini
[wsl2]
# Mirrored mode makes WSL interfaces match Windows interfaces 1:1
networkingMode=mirrored
# dnsTunneling allows Windows to handle DNS for corporate VPNs/Wi-Fi
dnsTunneling=true
# hostAddressLoopback allows LAN access to WSL services via Host IP
hostAddressLoopback=true

```

*After saving, run `wsl --shutdown` in PowerShell.*

### B. Route & Interface Metrics (PowerShell Admin)

Standardize metrics to ensure Windows prioritizes the Internet over the Lab for general traffic.

```powershell
# Set Wi-Fi to high priority
Set-NetIPInterface -InterfaceAlias "Wi-Fi" -InterfaceMetric 10

# Set Lab Switch to low priority (prevents "Internet" leaks into the lab)
Set-NetIPInterface -InterfaceAlias "vEthernet (vSwitch-Dev)" -InterfaceMetric 500

# Set Lab to 'Private' to ensure the Windows Firewall permits DNS traffic
$Profile = Get-NetConnectionProfile -InterfaceAlias "vEthernet (vSwitch-Dev)"
Set-NetConnectionProfile -InterfaceIndex $Profile.InterfaceIndex -NetworkCategory Private

```

---

## 2. The Linux Orchestrator Implementation

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

# 2. Reset Phase
# Clear stale settings from all virtual interfaces
for i in $(ls /sys/class/net | grep eth); do /usr/bin/resolvectl revert "$i"; done

# 3. Lab Mapping (rse.local)
if [ -n "$LAB_IF" ]; then
    /usr/bin/resolvectl dns "$LAB_IF" 172.19.2.100 172.19.2.101
    /usr/bin/resolvectl domain "$LAB_IF" "~rse.local"
    /usr/bin/resolvectl default-route "$LAB_IF" no
fi

# 4. Internet Mapping (Global Fallback)
if [ -n "$INET_IF" ]; then
    # Pointing to 8.8.8.8 triggers the Windows DNS Tunneling driver 
    # to intercept the port 53 traffic and resolve via the Host stack.
    /usr/bin/resolvectl dns "$INET_IF" 8.8.8.8 1.1.1.1
    /usr/bin/resolvectl domain "$INET_IF" "~."
    /usr/bin/resolvectl default-route "$INET_IF" yes

    # Disable noise protocols that cause timeout hangs
    /usr/bin/resolvectl dnssec "$INET_IF" no
    /usr/bin/resolvectl llmnr "$INET_IF" no
    /usr/bin/resolvectl mdns "$INET_IF" no
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

## 3. Global Installation Command

Execute this block as **root** to clean up old configurations and deploy the Orchestrator. This ensures a "Clean Slate" environment.

```bash
# 1. Cleanup old services
systemctl disable --now rse-split-dns.service 2>/dev/null || true
rm -f /etc/systemd/system/rse-split-dns.service

# 2. Set Permissions and Link Resolver
chmod +x /usr/local/bin/rse-dns-orchestrator.sh
ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf

# 3. Enable and Trigger
systemctl daemon-reload
systemctl enable --now systemd-resolved
systemctl enable --now rse-dns-orchestrator.service

```

---

## 4. Verification

| Target | Command | Expected Result |
| --- | --- | --- |
| **Status** | `resolvectl status` | `~rse.local` on Lab Link; `~.` on Internet Link |
| **Lab DNS** | `resolvectl query mos01.rse.local` | Resolves via 172.19.2.x (~1.5ms) |
| **Global DNS** | `resolvectl query www.ibm.com` | Resolves instantly (via Windows Tunnel) |
