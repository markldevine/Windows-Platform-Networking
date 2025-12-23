#!/usr/bin/bash
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
