Windows Host Standardization

We will pin the metrics so that Windows always knows the priority: **Internet first, Lab second.**

### 1. The PowerShell "Fix" (Run as Admin)

This script standardizes your adapter metrics. It ensures that your Wi-Fi/Ethernet always "wins" the default route, while your Lab remains a dedicated side-channel.

```powershell
# 1. Set Wi-Fi to high priority (Metric 10)
Set-NetIPInterface -InterfaceAlias "Wi-Fi" -InterfaceMetric 10

# 2. Set Ethernet to highest priority (Metric 5 - if plugged in)
Get-NetAdapter | Where-Object {$_.Name -like "*Ethernet*" -and $_.Status -eq "Up"} | Set-NetIPInterface -InterfaceMetric 5

# 3. Set the Lab Switch to low priority (Metric 500)
# This prevents Windows from ever trying to use the Lab for general internet.
Set-NetIPInterface -InterfaceAlias "vEthernet (vSwitch-Dev)" -InterfaceMetric 500

# 4. Set the Lab Network to 'Private' to ensure the Firewall doesn't block DNS
$Profile = Get-NetConnectionProfile -InterfaceAlias "vEthernet (vSwitch-Dev)"
Set-NetConnectionProfile -InterfaceIndex $Profile.InterfaceIndex -NetworkCategory Private

```

---

## Part 2: The Final Orchestrator Gist

This is the "Source of Truth" configuration for your RSE project.

### **The RSE "Zero-Touch" Networking Design**

> **Objective:** A portable, robust networking environment for WSL2 that resolves internal Lab services via split-DNS while maintaining corporate VPN/Internet stability.

#### **I. Windows Configuration (`.wslconfig`)**

*Required on all machines.*

```ini
[wsl2]
networkingMode=mirrored
dnsTunneling=true
hostAddressLoopback=true

```

#### **II. The Linux Orchestrator Script**

**File:** `/usr/local/bin/rse-dns-orchestrator.sh`
This script uses **"Subnet Fingerprinting"** to find the Lab, regardless of whether it appears on `eth0` or `eth4`.

```bash
#!/bin/bash
# RSE DNS ORCHESTRATOR - v2.0 (Mirrored Mode Optimized)

# 1. Discovery: Identify Lab by its 172.19.2.x subnet
LAB_IF=$(ip -4 -o addr show | grep "172.19.2." | awk '{print $2}' | head -n1)

# 2. Discovery: Identify Internet by the active Default Gateway
INET_IF=$(ip -4 route show default | awk '{print $5}' | head -n1)
INET_GW=$(ip -4 route show default | awk '{print $3}' | head -n1)

# 3. Clean Slate: Reset systemd-resolved links
for iface in $(ls /sys/class/net | grep eth); do /usr/bin/resolvectl revert "$iface"; done

# 4. Configure Lab Link
if [ -n "$LAB_IF" ]; then
    /usr/bin/resolvectl dns "$LAB_IF" 172.19.2.100 172.19.2.101
    /usr/bin/resolvectl domain "$LAB_IF" "~rse.local"
    /usr/bin/resolvectl default-route "$LAB_IF" no
fi

# 5. Configure Internet Link
if [ -n "$INET_IF" ]; then
    /usr/bin/resolvectl dns "$INET_IF" "$INET_GW"
    /usr/bin/resolvectl domain "$INET_IF" "~."
    /usr/bin/resolvectl default-route "$INET_IF" yes
    /usr/bin/resolvectl dnssec "$INET_IF" no
fi

/usr/bin/resolvectl flush-caches

```

#### **III. Automation (Systemd)**

**File:** `/etc/systemd/system/rse-dns-orchestrator.service`

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

## Why this is the "Best Practice" for Roaming

1. **Metric Shielding:** By setting the Windows Lab metric to 500, we prevent Windows from getting confused when you move between Wi-Fi networks.
2. **Firewall Awareness:** Moving the Lab switch to the "Private" category ensures that Windows Defender doesn't treat your `dnsmasq` responses as an attack.
3. **Dynamic Learning:** The Linux script doesn't care if you are at home (192.168.x.x) or at work (10.x.x.x). It only looks for the **Default Route** and the **Lab Fingerprint**.

### Final Verification Command

After rebooting and letting the orchestrator run, your `resolvectl status` should show exactly **one** link with `Default Route: yes` and **one** link (your Lab) with `DNS Domain: ~rse.local`.

Would you like me to create a single **"RSE-Provision.sh"** script that your colleagues can run to automate all of the Linux-side steps (symlinking, service creation, and script installation) in one go?
