This implementation follows the **"Orchestrator Pattern"** for WSL2. It is designed to be idempotent: running it multiple times or on top of old configurations will simply overwrite and deconflict the environment to reach the desired state.

---

## Part 1: The Windows Configuration

Before the Linux side can work, the Windows host must be set to **Mirrored Mode**. This ensures that WSL sees the actual network interfaces and can deconflict DNS at the kernel level.

**File:** `%USERPROFILE%\.wslconfig` (e.g., `C:\Users\Mark\.wslconfig`)

```ini
[wsl2]
# Mirrored mode makes WSL interfaces match Windows interfaces 1:1
networkingMode=mirrored
# dnsTunneling allows Windows to intercept DNS and route it through VPNs/Work Wi-Fi
dnsTunneling=true
# hostAddressLoopback allows LAN/External access to WSL services via the host IP
hostAddressLoopback=true

```

*Note: Run `wsl --shutdown` in PowerShell after saving this file.*

---

## Part 2: The Unified Linux Orchestrator

This script is the "brain." It performs environment discovery to find where your Lab (RSE) and the Internet (World) live today.

**File:** `/usr/local/bin/rse-dns-orchestrator.sh`

```bash
#!/bin/bash
# ==============================================================================
# RSE DYNAMIC DNS ORCHESTRATOR
# Description: Automatically detects Lab vs. Internet interfaces and maps DNS.
# Support: Mirrored Mode, VPNs, Home/Work/Roaming.
# ==============================================================================

# Ensure we are running as root
if [ "$EUID" -ne 0 ]; then echo "Please run as root"; exit 1; fi

# 1. SETTLE TIME: Wait for virtual interfaces to initialize
sleep 2

# 2. DECONFLICT: Revert all current resolvectl settings to a clean state.
# This removes any manual 'resolvectl' overrides from previous sessions.
for iface in $(ls /sys/class/net | grep eth); do
    /usr/bin/resolvectl revert "$iface"
done

# 3. DISCOVERY: Find the RSE Lab interface by its unique subnet (172.19.2.x)
LAB_IF=$(ip -4 -o addr show | grep "172.19.2." | awk '{print $2}' | head -n1)

# 4. DISCOVERY: Find the Internet interface (the one holding the default route)
# We exclude the Lab interface to ensure we don't treat the Lab as the Internet.
INET_IF=$(ip -4 route show default | grep -v "$LAB_IF" | awk '{print $5}' | head -n1)
INET_GW=$(ip -4 route show default | grep -v "$LAB_IF" | awk '{print $3}' | head -n1)

# 5. CONFIGURE LAB (rse.local)
if [ -n "$LAB_IF" ]; then
    echo "Discovery: Lab Subnet found on $LAB_IF"
    # Map the primary Lab DNS (dnsmasq master) and backups
    /usr/bin/resolvectl dns "$LAB_IF" 172.19.2.100 172.19.2.101
    # Routing Domain: The '~' means 'use this interface specifically for this domain'
    /usr/bin/resolvectl domain "$LAB_IF" "~rse.local"
    # Never use the Lab interface for global (internet) traffic
    /usr/bin/resolvectl default-route "$LAB_IF" no
else
    echo "Discovery: RSE Lab subnet (172.19.2.x) not found."
fi

# 6. CONFIGURE INTERNET (Global Fallback)
if [ -n "$INET_IF" ]; then
    echo "Discovery: Internet Gateway ($INET_GW) found on $INET_IF"
    # In dnsTunneling mode, pointing to the gateway (172.16.0.1 or similar)
    # allows Windows to handle VPN-aware resolution automatically.
    /usr/bin/resolvectl dns "$INET_IF" "$INET_GW"
    # Routing Domain: The '~.' is the 'wildcard' domain (everything else)
    /usr/bin/resolvectl domain "$INET_IF" "~."
    # This interface is the authoritative path for general internet traffic
    /usr/bin/resolvectl default-route "$INET_IF" yes
    # Disable DNSSEC/LLMNR to prevent 'degraded feature set' logs in corporate environments
    /usr/bin/resolvectl dnssec "$INET_IF" no
    /usr/bin/resolvectl llmnr "$INET_IF" no
else
    echo "Discovery: No default internet gateway detected."
fi

# 7. REFRESH: Flush caches to ensure new logic takes immediate effect
/usr/bin/resolvectl flush-caches
echo "Status: DNS Orchestration Complete."

```

---

## Part 3: The Systemd Integration

This ensures the script runs at boot and that the system uses `systemd-resolved` as its DNS engine.

### A. The Automation Service

**File:** `/etc/systemd/system/rse-dns-orchestrator.service`

```ini
[Unit]
Description=RSE Dynamic DNS Orchestrator
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
# RemainAfterExit=yes keeps the service marked as 'active' after the script finishes
RemainAfterExit=yes
ExecStart=/usr/local/bin/rse-dns-orchestrator.sh

[Install]
# Ensures this runs during the multi-user (normal) boot sequence
WantedBy=multi-user.target

```

### B. Deployment Commands

Copy-paste these commands to finalize the "Clean Slate" implementation:

```bash
# 1. Secure the script
sudo chmod +x /usr/local/bin/rse-dns-orchestrator.sh

# 2. Force systemd-resolved to manage DNS (The Clean Slate)
# Removing old resolv.conf and linking the stub resolver
sudo rm -f /etc/resolv.conf
sudo ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf

# 3. Enable and Start the services
sudo systemctl daemon-reload
sudo systemctl enable --now systemd-resolved
sudo systemctl enable --now rse-dns-orchestrator.service

# 4. Verify
resolvectl status

```

---

## Summary for Your Gist

* **Logic:** Detects the Lab subnet `172.19.2.x` on any interface index (`eth0`, `eth1`, etc.).
* **Split DNS:** Routes `*.rse.local` to your internal servers and everything else (`~.`) to the Windows-managed gateway.
* **VPN-Proof:** Uses the dynamic gateway address which Windows updates whenever your VPN connects/disconnects.
* **Clean Slate:** `resolvectl revert` ensures that no manual settings from a "previous Wi-Fi" session stick around to break your current session.

Would you like me to add a **Udev rule** snippet to the Gist so that this script automatically re-runs if you plug in a physical Ethernet cable while the machine is already running?
