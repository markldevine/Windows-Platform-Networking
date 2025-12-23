This transition represents a move to a high-precision, production-grade networking architecture. By standardizing on the **Orchestrator Pattern**, you are ensuring that your environment is self-healing and "environment-aware," regardless of whether it's running on a stationary desktop or a roaming laptop.

---

## The Precision Design: RSE Dynamic DNS Orchestrator

This design replaces all previous ad-hoc split-DNS attempts. It leverages **Subnet Fingerprinting** to identify your Lab and **Gateway Tracking** to identify your internet path.

### 1. Windows Host Standardization (`.wslconfig`)

This file is the "Master Switch" for the entire architecture. Ensure this is identical across all machines.

**Path:** `%USERPROFILE%\.wslconfig`

```ini
[wsl2]
# Mirrored mode makes WSL interfaces match Windows interfaces 1:1
networkingMode=mirrored
# dnsTunneling allows Windows to handle DNS resolution for corporate VPNs/Wi-Fi
dnsTunneling=true
# hostAddressLoopback allows your WSL services to be reachable on your LAN
hostAddressLoopback=true

```

---

### 2. The Implementation Script

This script is idempotent; it can be run as an install script or a repair script. It handles the renaming and deconfliction of the old service automatically.

**Run as root in WSL2:**

```bash
#!/bin/bash
# ==============================================================================
# RSE ORCHESTRATOR DEPLOYMENT - PRECISION VERSION
# ==============================================================================

# 1. Deconflict: Remove the old service if it exists
echo ">>> Cleaning up previous service: rse-split-dns..."
systemctl disable --now rse-split-dns.service 2>/dev/null || true
rm -f /etc/systemd/system/rse-split-dns.service

# 2. Install Logic: Create the Orchestrator Script
echo ">>> Installing Orchestrator logic to /usr/local/bin/..."
cat << 'EOF' > /usr/local/bin/rse-dns-orchestrator.sh
#!/bin/bash
# Discovery Phase: Identify Lab (172.19.2.x) and Internet (Default Gateway)
LAB_IF=$(ip -4 -o addr show | grep "172.19.2." | awk '{print $2}' | head -n1)
INET_IF=$(ip -4 route show default | awk '{print $5}' | head -n1)
INET_GW=$(ip -4 route show default | awk '{print $3}' | head -n1)

# Reset: Clear stale Resolve settings for all ethernet interfaces
for i in $(ls /sys/class/net | grep eth); do /usr/bin/resolvectl revert "$i"; done

# Logic Block: RSE Lab (High Priority/Specificity)
if [ -n "$LAB_IF" ]; then
    /usr/bin/resolvectl dns "$LAB_IF" 172.19.2.100 172.19.2.101
    /usr/bin/resolvectl domain "$LAB_IF" "~rse.local"
    /usr/bin/resolvectl default-route "$LAB_IF" no
    echo "Orchestrator: Lab fingerprint detected on $LAB_IF"
fi

# Logic Block: Global Internet (Authoritative Default Route)
if [ -n "$INET_IF" ]; then
    /usr/bin/resolvectl dns "$INET_IF" "$INET_GW"
    /usr/bin/resolvectl domain "$INET_IF" "~."
    /usr/bin/resolvectl default-route "$INET_IF" yes
    # Disable protocols that often trigger "degraded feature set" warnings in corporate LANs
    /usr/bin/resolvectl dnssec "$INET_IF" no
    /usr/bin/resolvectl llmnr "$INET_IF" no
    echo "Orchestrator: Internet gateway detected on $INET_IF via $INET_GW"
fi
/usr/bin/resolvectl flush-caches
EOF
chmod +x /usr/local/bin/rse-dns-orchestrator.sh

# 3. Service Creation: Create the new Orchestrator System Unit
echo ">>> Creating rse-dns-orchestrator.service..."
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

# 4. Global Resolver Configuration
echo ">>> Finalizing clean-slate resolver link..."
ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf

# 5. Activation
echo ">>> Activating Orchestrator..."
systemctl daemon-reload
systemctl enable --now systemd-resolved
systemctl enable --now rse-dns-orchestrator.service

echo ">>> Deployment Successful."

```

---

### 3. Architecture Summary for Your Project Documentation

| Feature | Design Implementation |
| --- | --- |
| **Discovery** | Uses `grep "172.19.2."` to find the Lab interface regardless of index shuffling. |
| **Routing** | Uses `~rse.local` (specific) vs `~.` (wildcard) to implement split-horizon resolution. |
| **VPN Support** | Inherits `$INET_GW` dynamically, respecting Windows DNS Tunneling. |
| **Idempotency** | `resolvectl revert` ensures that moving between WiFi networks doesn't leave stale DNS servers behind. |

#### **Testing your Precision Build:**

1. **Lab Check:** `resolvectl query mos01.rse.local` (Targeting 172.19.2.x via Lab IF)
2. **Internet Check:** `resolvectl query www.google.com` (Targeting Windows GW via Internet IF)

If you ever find yourself on a new network and things feel slow, a simple `sudo systemctl restart rse-dns-orchestrator` will re-run the discovery and map the world to your current reality.

[WSL 2 Networking - YouTube](https://www.youtube.com/watch?v=yCK3easuYm4)

This video explains the fundamental shift in WSL2 networking architecture, which helps in understanding why manual overrides are necessary to maintain stable DNS in complex corporate or roaming environments.
