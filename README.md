# WSL2 Mirrored Mode Networking Fix — `ip_local_port_range` vs Windows FSE Switch

> **TL;DR**: If **WSL2 NAT mode works**, and in **Mirrored mode (`networkingMode=mirrored`)** DNS + ICMP `ping` both work, **yet all outbound TCP connections (`curl`, `git`, `apt`, HTTPS) time out (`curl: (28)`)** with **0 packets captured by Windows `PktMon`**, check whether a Linux `/etc/sysctl.d/*.conf` file overwrote `net.ipv4.ip_local_port_range` (e.g., `10000 65535`). In Mirrored mode, Windows `FSE Switch` assigns WSL a strict 4,096-port ephemeral block per boot (visible in `nft list chain ip nat WSLPOSTROUTING`); any outbound TCP/UDP packet using a source port outside that range is silently dropped at the FSE vNIC boundary.

---

## 一、 症状特征（Windows 11 25H2 Build 26200 + WSL 3.0.5.0）

- **NAT 模式**：一切正常。
- **Mirrored 模式（`networkingMode=mirrored`）**：
  - 虚拟交换机与网卡镜像成功，Linux 内可见宿主机局域网 IP（如 `192.168.124.3/24`）及默认路由；
  - DNS 隧道正常（`10.255.255.254:53` 秒级解析域名）；
  - `ping` 网关与公网 IP（如 `223.5.5.5`）**6 ms 零丢包**；
  - **所有 Linux 出站 TCP 连接（`curl -4`、`git`、`apt`、HTTPS）全部超时**（`Connection timed out`）；
  - Linux `/proc/net/dev` 显示镜像网卡 TX 包计数增加，但 Windows 宿主机运行 `pktmon start --capture --comp all` 对目标 IP:443 抓包结果为 **0 个出站 TCP 包**。

---

## 二、 核心根因

在 WSL2 **Mirrored** 模式下，Linux 与 Windows 宿主机共享同一个物理网卡 IP。为避免宿主机与 WSL 争抢临时源端口，Windows 的 `FSE Switch`（`fse.sys` / `HNS`）每次冷启动都会为 WSL 动态划拨一段 **4096 个连续临时端口**（例如 `43255-47350`），并在启动时：

1. 将该区间下发到 Linux 内核 `nftables` 规则 `table ip nat -> chain WSLPOSTROUTING`（`masquerade to :MIN-MAX`）；
2. 自动写入 `/proc/sys/net/ipv4/ip_local_port_range`。

而在本次环境中，Ubuntu 内的自定义 sysctl 文件 `/etc/sysctl.d/99-wsl-network-hardening.conf` 包含一行：

```ini
net.ipv4.ip_local_port_range = 10000 65535
```

systemd 在启动阶段加载该配置，将端口范围改回 `10000 65535`。于是：
- **>92% 的 Linux 出站 TCP/UDP 连接选用了 `FSE Switch` 授权范围之外的源端口**；
- 数据包虽从 Linux `ethX` 发出，但立刻在 Windows `FSE Switch` 虚拟网卡边界被静默丢弃（导致 Windows `PktMon` 捕获 0 包）；
- **为什么 ICMP `ping` 正常？** ICMP 协议没有源端口，不受临时端口区间校验限制；
- **为什么 DNS 正常？** `dnsTunneling=true` 走 `10.255.255.254` 虚拟化隧道；
- **为什么 NAT 模式正常？** NAT 使用独立私有子网（`172.x`），不与宿主机共享 IP，无 FSE 端口区间校验。

---

## 三、 高效诊断路径与已排除项

### 10 秒定位命令（在 WSL 内以 root 运行）
```bash
echo "=== Kernel Port Range ==="
cat /proc/sys/net/ipv4/ip_local_port_range
echo "=== WSL FSE Port Range (nft) ==="
nft list chain ip nat WSLPOSTROUTING | head -n 8
echo "=== Conflicting sysctl Rules ==="
grep -rn "ip_local_port_range" /etc/sysctl.conf /etc/sysctl.d/ /usr/lib/sysctl.d/ /run/sysctl.d/ 2>/dev/null
```

### 排查排除链路（完整复盘）
1. 升级 WSL 至 `3.0.5.0` → 仍复现（排除旧版 WSL 已知 Bug）；
2. 清理第三方残留 WFP 驱动（`nfwfp.sys`）并重启 Windows → 仍复现（排除宿主 WFP 驱动冲突）；
3. 测试关闭 Hyper-V 防火墙与安全软件、恢复物理网卡 TCP Checksum Offload → 仍复现；
4. 对比 `ping 223.5.5.5`（通） vs `curl -4 https://223.5.5.5`（超时），并结合 Windows `PktMon --comp all`（0 包）vs Linux `/proc/net/dev`（TX 增长）→ 锁定包在 Linux 出站至 FSE 边界之间被丢；
5. 停用与 WSL `nftables` `WSLOUTPUT` 链存在表兼容警告的 Ubuntu `ufw` → 仍超时；
6. 比对 `/proc/sys/net/ipv4/ip_local_port_range` (`10000 65535`) 与 `WSLPOSTROUTING` (`43255-47350`) → **立即锁定根因**。

---

## 四、 永久修复与验收结果

### 修复步骤
1. 注释掉 `/etc/sysctl.d/` 中的 `net.ipv4.ip_local_port_range`（保留其余安全的 TCP 缓冲调优参数）：
   ```bash
   sudo sed -i 's/^net\.ipv4\.ip_local_port_range/#net.ipv4.ip_local_port_range/' /etc/sysctl.d/99-wsl-network-hardening.conf
   ```
2. 如不需要宿主机旁路防火墙且看到 `iptables-save` 提示 `incompatible base-chains`，保持 Ubuntu `ufw disable`：
   ```bash
   sudo ufw disable
   ```
3. 在 Windows PowerShell 重启 WSL：
   ```powershell
   wsl --shutdown
   ```
4. （可选）校对 `%UserProfile%\.wslconfig` 段位（`dnsTunneling`/`firewall`/`autoProxy` 放 `[wsl2]`，`hostAddressLoopback`/`autoMemoryReclaim` 放 `[experimental]`），参见 [`configs/.wslconfig.recommended`](configs/.wslconfig.recommended)。

### 实机验收结果
- **端口区间对齐**：`ip_local_port_range` 与 `WSLPOSTROUTING` 严格一致（如 `43255 47350` / `39160 43255`）；
- **直连模式（TUN 关闭）**：`223.5.5.5`（`HTTP/2 404`）、`www.bing.com`（`HTTP/2 302`）秒通；
- **代理模式（Mihomo / FlClash TUN 开启）**：`eth0 (198.18.0.0/30)` 与 `eth3` 同步镜像，`github.com` / `google.com` / `bing.com` 均 `HTTP/2 200`；
- **热切换验证**：直连 ↔ TUN 反复开关无需 `wsl --shutdown`；
- **开启安全软件与防火墙后吞吐测试**：1 MB HTTPS 下载 `0.67s`（约 `1.56 MB/s`），稳定无断流。

---

## 五、 仓库结构与一键体检脚本

- [`scripts/check-wsl-mirrored.sh`](scripts/check-wsl-mirrored.sh)：只读诊断脚本，自动核对 `ip_local_port_range` 与 `WSLPOSTROUTING` 区间、扫描 `/etc/sysctl.d/` 冲突项、检查 `ufw` 状态与策略路由表 `127/128`：
  ```bash
  sudo bash scripts/check-wsl-mirrored.sh
  # 附带外网连通性测试：
  sudo bash scripts/check-wsl-mirrored.sh --net
  ```
- [`configs/.wslconfig.recommended`](configs/.wslconfig.recommended)：推荐的 `.wslconfig` 段位配置模板
- [`configs/99-wsl-mirrored.conf`](configs/99-wsl-mirrored.conf)：Mirrored 模式安全的回环/转发内核参数模板
- [`configs/99-wsl-network-hardening.conf`](configs/99-wsl-network-hardening.conf)：已移除 `ip_local_port_range` 冲突的安全 TCP 调优模板
- [`COMMUNITY-POST-microsoft-WSL.md`](COMMUNITY-POST-microsoft-WSL.md)：社区分享文稿
