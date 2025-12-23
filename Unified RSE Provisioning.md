The error you saw on Step 2 is actually a "success" in disguise: it occurred because you have no physical Ethernet cable plugged in, and the command tried to apply a metric to a virtual container interface (`FSE HostVnic`) that doesn't support standard IP interface settings. You can safely ignore it.

Your Windows host is now professionally "tethered"—it knows that the **RSE Lab** is a side-channel (Metric 500) and that **Wi-Fi** is the preferred gateway (Metric 10).

---

## The Unified RSE Provisioning Gist

This is the "Source of Truth" document for you and your colleagues. It consolidates all our findings into a single, repeatable deployment.

### 1. Windows Host Prep (One-time)

Ensure `%USERPROFILE%\.wslconfig` is set:

```ini
[wsl2]
networkingMode=mirrored
dnsTunneling=true
hostAddressLoopback=true

```

### 2. The Linux "Clean Slate" Provisioner

Create a file named `provision-rse-dns.sh` in your WSL home directory. This script automates the overwrite/update of all configurations we've discussed.

```bash
#!/bin/bash
# ==============================================================================
# RSE Provisioning Script - Unified DNS Orchestrator
# ==============================================================================

set -e # Exit on error

echo "Starting RSE DNS Provisioning..."

# 1. Create the Orchestrator Script
cat << 'EOF' | sudo tee /usr/local/bin/rse-dns-orchestrator.sh > /dev/null
#!/bin/bash
# Discovery Logic: Find Lab (172.19.2.x) and Internet (Default Route)
LAB_IF=$(ip -4 -o addr show | grep "172.19.2." | awk '{print $2}' | head -n1)
INET_IF=$(ip -4 route show default | awk '{print $5}' | head -n1)
INET_GW=$(ip -4 route show default | awk '{print $3}' | head -n1)

# Reset all link configurations to avoid stale metric/DNS conflicts
for iface in $(ls /sys/class/net | grep eth); do /usr/bin/resolvectl revert "$iface"; done

# Map Lab (High specificity)
if [ -n "$LAB_IF" ]; then
    /usr/bin/resolvectl dns "$LAB_IF" 172.19.2.100 172.19.2.101
    /usr/bin/resolvectl domain "$LAB_IF" "~rse.local"
    /usr/bin/resolvectl default-route "$LAB_IF" no
fi

# Map Internet (Global Fallback)
if [ -n "$INET_IF" ]; then
    /usr/bin/resolvectl dns "$INET_IF" "$INET_GW"
    /usr/bin/resolvectl domain "$INET_IF" "~."
    /usr/bin/resolvectl default-route "$INET_IF" yes
    /usr/bin/resolvectl dnssec "$INET_IF" no
fi
/usr/bin/resolvectl flush-caches
EOF

sudo chmod +x /usr/local/bin/rse-dns-orchestrator.sh

# 2. Create the Systemd Service
cat << 'EOF' | sudo tee /etc/systemd/system/rse-dns-orchestrator.service > /dev/null
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

# 3. Finalize systemd-resolved and resolv.conf
echo "Finalizing systemd configuration..."
sudo systemctl enable --now systemd-resolved
sudo rm -f /etc/resolv.conf
sudo ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf

# 4. Trigger the first run
sudo systemctl daemon-reload
sudo systemctl enable --now rse-dns-orchestrator.service

echo "Provisioning Complete. Testing resolution..."
echo "------------------------------------------------"
resolvectl status | grep -E "Link|Default Route|DNS Domain|Servers"

```

---

## Why this works as a "Permanent Solution"

1. **Metric Harmonization:** Windows now gives the Lab a metric of 500. This means Windows itself will never try to send a packet to `google.com` via the Lab switch, even if Wi-Fi drops.
2. **Fingerprint Discovery:** The Linux script doesn't care if your lab is on `eth0` or `eth4`. It looks for the subnet. This solves the "Interface Shuffle" forever.
3. **Tunneling-Ready:** By using the dynamic `$INET_GW` in the script, we respect Windows' DNS Tunneling interceptor.
4. **Colleague-Friendly:** You can simply hand your colleagues the `.wslconfig` and the `provision-rse-dns.sh` script.

---

### Verification

Run `resolvectl query www.ibm.com` and `resolvectl query mos01.rse.local`.

If both return results instantly, you have successfully outsmarted the Windows networking stack.

**Would you like me to add a section to the Gist regarding how to handle a corporate VPN that might require an additional search domain to be added to the Internet interface?**
