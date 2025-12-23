This README and the associated "One-Line Installer" provide the definitive configuration for the **RSE Dynamic DNS Orchestrator**.

This design outsmarts the standard Windows/WSL2 networking limitations by using **Subnet Fingerprinting** to find your Lab and **DNS Tunneling** to bypass corporate firewall/VPN restrictions.

---

## 1. The Architecture

In **Mirrored Mode**, WSL2 sees the exact network environment as Windows. Our Orchestrator acts as the "Traffic Cop," ensuring queries for your private dev environment stay internal while the rest of the world routes through the Windows Host.

---

## 2. Phase 1: Windows Host Prep (Mandatory)

Before running the Linux installer, your Windows Host must be in the correct mode.

1. Open PowerShell and type: `notepad $env:USERPROFILE\.wslconfig`
2. Ensure the file contains exactly this:
```ini
[wsl2]
networkingMode=mirrored
dnsTunneling=true
hostAddressLoopback=true

```


3. **Restart WSL:** Run `wsl --shutdown` in PowerShell.

---

## 3. Phase 2: The "One-Line" Linux Installer

Copy and paste this into your WSL2 (OpenSUSE) terminal to automate the entire setup. This script is idempotent (safe to run multiple times).

```bash
curl -s https://raw.githubusercontent.com/your-repo/rse-provision.sh | sudo bash

```

### Manual Installation (The "Clean Slate" Method)

If you prefer to run it manually, execute this block as **root**:

```bash
#!/bin/bash
# RSE Orchestrator Deployment Script

# 1. Cleanup old services
systemctl disable --now rse-split-dns.service 2>/dev/null || true
rm -f /etc/systemd/system/rse-split-dns.service

# 2. Create the Orchestrator Script
cat << 'EOF' > /usr/local/bin/rse-dns-orchestrator.sh
#!/bin/bash
# Discovery: Identify Lab (172.19.2.x) and Internet (Default Gateway)
LAB_IF=$(ip -4 -o addr show | grep "172.19.2." | awk '{print $2}' | head -n1)
INET_IF=$(ip -4 route show default | awk '{print $5}' | head -n1)

# Reset: Clear previous resolve settings
for i in $(ls /sys/class/net | grep eth); do /usr/bin/resolvectl revert "$i"; done

# Map Lab (rse.local)
if [ -n "$LAB_IF" ]; then
    /usr/bin/resolvectl dns "$LAB_IF" 172.19.2.100 172.19.2.101
    /usr/bin/resolvectl domain "$LAB_IF" "~rse.local"
    /usr/bin/resolvectl default-route "$LAB_IF" no
fi

# Map Internet (Global Fallback) - Uses 8.8.8.8 to trigger Windows DNS Tunneling
if [ -n "$INET_IF" ]; then
    /usr/bin/resolvectl dns "$INET_IF" 8.8.8.8 1.1.1.1
    /usr/bin/resolvectl domain "$INET_IF" "~."
    /usr/bin/resolvectl default-route "$INET_IF" yes
    /usr/bin/resolvectl dnssec "$INET_IF" no
    /usr/bin/resolvectl llmnr "$INET_IF" no
    /usr/bin/resolvectl mdns "$INET_IF" no
fi
/usr/bin/resolvectl flush-caches
EOF
chmod +x /usr/local/bin/rse-dns-orchestrator.sh

# 3. Create the Systemd Service
cat << 'EOF' > /etc/systemd/system/rse-dns-orchestrator.service
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
EOF

# 4. Finalize Link and Activate
ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
systemctl daemon-reload
systemctl enable --now systemd-resolved
systemctl enable --now rse-dns-orchestrator.service

```

---

## 4. Key Features for Roaming

* **Zero-Hardcoding:** Detects the Lab subnet `172.19.2.x` on any interface index (`eth0`, `eth1`, etc.).
* **Split-Horizon:** Only `*.rse.local` queries go to your internal servers. All other traffic is handled by the Windows host.
* **VPN Compatibility:** By targeting `8.8.8.8` on the internet interface, we trigger the Windows **DNS Tunneling** driver, which intercepts the request and handles VPN-specific resolution automatically.

---

## 5. Verification

After installation, verify the "split" is working:

| Test | Command | Expected Result |
| --- | --- | --- |
| **Lab DNS** | `resolvectl query mos01.rse.local` | Resolve via Lab Interface (~1.8ms) |
| **Global DNS** | `resolvectl query www.ibm.com` | Resolve via Internet Interface (Instant) |
| **Route Check** | `resolvectl status` | `~.` marked as Default Route on the Internet link |

---

**Would you like me to create a small "Health Check" script that you can run anytime to ensure your metrics and routes are still in their best-practice state?**
