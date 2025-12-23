Dynamic DNS Orchestrator
========================
### **The Design: "Zero-Touch" Split DNS for Corporate WSL2**

> **Goal:** Resolve internal lab resources (`*.rse.local`) via a private DNS server while routing all other traffic through the Windows/VPN stack, surviving reboots and roaming.

#### **I. Windows Setup (The Foundation)**

Create `%USERPROFILE%\.wslconfig`:

```ini
[wsl2]
networkingMode=mirrored
dnsTunneling=true
hostAddressLoopback=true

```

#### **II. The Linux Logic (The Orchestrator)**

Instead of hardcoding interface names (which shuffle), we detect the environment via the subnet signature.

**The Script:** `/usr/local/bin/rse-dns-orchestrator.sh`

1. **Revert:** Clears all existing `resolvectl` settings to prevent "Default Route" conflicts.
2. **Discover Lab:** Looks for the interface on the `172.19.2.0/24` subnet.
3. **Discover Internet:** Identifies the interface holding the `default` route.
4. **Map:** * Assigns `~rse.local` to the Lab interface.
* Assigns `~.` (the wildcard) to the Internet interface.
* Explicitly sets the Internet interface as the `Default Route`.



#### **III. Deployment Steps**

1. **Enable systemd-resolved:** Link the stub resolver to `/etc/resolv.conf`.
2. **Install Script:** Copy the Orchestrator to `/usr/local/bin/`.
3. **Automation:** Enable the systemd service to run the script at every boot.

---

## 4. The "Outsmarting" Automation (Udev Rule)

To truly "set it and forget it" on your laptop, we don't need `NetworkManager`. We just need a **Udev rule**. This tells Linux: *"Every time a network interface changes state (like when you wake from sleep or connect a VPN), re-run my Orchestrator script."*

**Create `/etc/udev/rules.d/99-wsl-dns.rules`:**

```text
SUBSYSTEM=="net", ACTION=="add", RUN+="/usr/local/bin/rse-dns-orchestrator.sh"
SUBSYSTEM=="net", ACTION=="change", RUN+="/usr/local/bin/rse-dns-orchestrator.sh"

```
