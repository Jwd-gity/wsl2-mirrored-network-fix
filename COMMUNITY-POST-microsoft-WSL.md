## Symptoms

Sharing a hard-won root cause for anyone stuck in **WSL2 Mirrored Mode** (`networkingMode=mirrored`) with this exact pattern:

- **NAT mode** works completely fine.
- **Mirrored mode** initializes cleanly (no `0x8007054f` fallback):
  - Mirrored LAN IP & default route exist inside Linux (`ip -brief addr`).
  - **DNS tunneling works** (`10.255.255.254:53` resolves hostnames immediately).
  - **ICMP `ping` works** to both gateway and public IPv4 addresses (e.g. `223.5.5.5` in 6 ms, 0% loss).
  - **Every outbound TCP connection times out** (`curl -4 https://...` -> `curl: (28) Connection timed out`, `git`, `apt`, etc.).
- Even weirder: `/proc/net/dev` inside Linux shows TX packets incrementing on the mirrored `ethX` interface, yet **Windows `pktmon start --capture --comp all` captures ZERO (`0`) outbound TCP packets** on the Windows host!

Environment verified on: Windows 11 Pro 25H2 (Build `26200.8457`), WSL `3.0.5.0`, Ubuntu.

---

## Root Cause

In WSL2 Mirrored Mode, Linux shares the host IP address. To avoid port collisions between Windows and Linux, Windows `FSE Switch` / `HNS` dynamically allocates a strict **4,096-port ephemeral range** to WSL on every cold boot (for example `43255-47350`). WSL writes that range into:
1. `nftables` `table ip nat -> chain WSLPOSTROUTING` (`masquerade to :MIN-MAX`)
2. `/proc/sys/net/ipv4/ip_local_port_range`

In my distro, an older tuning file `/etc/sysctl.d/99-wsl-network-hardening.conf` contained:

```ini
net.ipv4.ip_local_port_range = 10000 65535
```

When systemd booted Ubuntu, `sysctl` overwrote `/proc/sys/net/ipv4/ip_local_port_range` back to `10000 65535`. Because >92% of Linux's ephemeral source ports now fell outside the 4,096-port range authorized by `FSE Switch`, almost every outbound TCP/UDP packet was **silently dropped at the FSE vNIC boundary** before ever hitting the Windows TCP/IP stack (`PktMon`).

That also explains all the symptoms:
- **Why did `ping` work?** ICMP has no source port, so FSE port-range enforcement did not drop it.
- **Why did DNS work?** `dnsTunneling=true` uses the virtualization tunnel (`10.255.255.254`).
- **Why did NAT mode work?** NAT uses an isolated private subnet instead of sharing the host IP.

---

## 10-Second Check

Run inside your WSL distro as root (`sudo` or `wsl -u root`):

```bash
echo "== Kernel port range =="; cat /proc/sys/net/ipv4/ip_local_port_range
echo "== WSLPOSTROUTING authorized range =="; nft list chain ip nat WSLPOSTROUTING | head -n 8
echo "== sysctl overrides =="; grep -rn "ip_local_port_range" /etc/sysctl.conf /etc/sysctl.d/ /usr/lib/sysctl.d/ /run/sysctl.d/ 2>/dev/null
```

If `/proc/sys/net/ipv4/ip_local_port_range` does **not** match `masquerade to :MIN-MAX` in `WSLPOSTROUTING` (e.g. kernel shows `10000 65535` or `32768 60999`), you hit this exact bug.

---

## Fix

1. Comment out or remove `net.ipv4.ip_local_port_range` from `/etc/sysctl.d/*.conf` or `/etc/sysctl.conf` (**do not hardcode** the current boot's range, because FSE allocates a fresh 4,096-port window on every WSL cold boot).
2. Restart WSL from PowerShell:
   ```powershell
   wsl --shutdown
   ```
3. Verify that `/proc/sys/net/ipv4/ip_local_port_range` now matches `WSLPOSTROUTING` and TCP works.

---

## Bonus Tips (Checked Along the Way)

- **Disable `ufw` inside WSL** if `iptables-save` warns `Table 'filter' contains incompatible base-chains` alongside WSL's `WSLOUTPUT` `nftables` chain (`sudo ufw disable`).
- **Check `.wslconfig` section placement**: `dnsTunneling`, `firewall`, and `autoProxy` belong under `[wsl2]`, while `hostAddressLoopback=true` currently still belongs under `[experimental]` (placing `hostAddressLoopback=true` under `[wsl2]` leaves `ip route show table 128` empty).
- **TUN Proxy Compatibility (Mihomo / Clash)**: Mirrored mode dynamically syncs TUN interface hot-toggling without `wsl --shutdown` once FSE port range alignment is intact.

---

## Diagnostic Script & Templates

I packaged a read-only check script (`check-wsl-mirrored.sh`), full postmortem notes, and safe `.wslconfig` / `sysctl.d` templates here for easy reuse:
https://github.com/Jwd-gity/wsl2-mirrored-network-fix

---

## 中文简明摘要

如果你在 **WSL2 镜像模式（`networkingMode=mirrored`）** 遇到：**NAT 模式完全正常；镜像模式下 DNS 解析与 `ping` 网关/公网（如 `223.5.5.5`）均正常，但所有出站 TCP（`curl` / `git` / `apt`）全部超时，且 Windows `PktMon` 抓不到任何出站 TCP 包**——重点排查 Ubuntu 的 `/etc/sysctl.d/*.conf` 是否配置了 `net.ipv4.ip_local_port_range`。

Windows `FSE Switch` 每次冷启动只为镜像模式动态分配 4096 个端口（可在 `nft list chain ip nat WSLPOSTROUTING` 看到），一旦 `sysctl` 将其覆盖为 `10000 65535` 等大范围，92%+ 的出站 TCP 会因源端口越界被虚拟交换机静默丢弃。注释掉该 `sysctl` 项后执行 `wsl --shutdown` 即可彻底恢复（包括与 Mihomo/FlClash TUN 模式的免重启热切换）。详情与一键自检脚本见上方 GitHub 仓库。
