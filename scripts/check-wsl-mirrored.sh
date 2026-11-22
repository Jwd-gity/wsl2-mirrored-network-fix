#!/usr/bin/env bash
# Read-only diagnostic tool for WSL2 Mirrored Mode networking.
# Checks ephemeral port range alignment with WSLPOSTROUTING (FSE Switch),
# scans sysctl configs for ip_local_port_range overrides, inspects ufw,
# policy routing tables 127/128, and optionally tests network connectivity.

set -u

CHECK_NET=0
if [[ "${1:-}" == "--net" ]]; then
  CHECK_NET=1
elif [[ -n "${1:-}" ]]; then
  echo "Usage: $0 [--net]"
  exit 2
fi

PASS=0
WARN=0
FAIL=0

ok()   { echo "[PASS] $*"; PASS=$((PASS + 1)); }
warn() { echo "[WARN] $*"; WARN=$((WARN + 1)); }
fail() { echo "[FAIL] $*"; FAIL=$((FAIL + 1)); }

echo "=== 1. Mirrored Interfaces ==="
ip -brief addr || true
echo

echo "=== 2. Ephemeral Port Range vs WSLPOSTROUTING (FSE Switch) ==="
if [[ -r /proc/sys/net/ipv4/ip_local_port_range ]]; then
  read -r CUR_MIN CUR_MAX < /proc/sys/net/ipv4/ip_local_port_range
  echo "Kernel /proc/sys/net/ipv4/ip_local_port_range: ${CUR_MIN} ${CUR_MAX}"
else
  fail "Cannot read /proc/sys/net/ipv4/ip_local_port_range"
  CUR_MIN=""
  CUR_MAX=""
fi

if command -v nft >/dev/null 2>&1; then
  if [[ $EUID -eq 0 ]]; then
    NFT_OUT="$(nft list chain ip nat WSLPOSTROUTING 2>/dev/null || true)"
    if [[ -z "$NFT_OUT" ]]; then
      warn "nft chain 'ip nat WSLPOSTROUTING' not found (are you in Mirrored mode?)"
    else
      NFT_RANGE="$(printf '%s\n' "$NFT_OUT" | grep -oE 'masquerade to :[0-9]+-[0-9]+' | head -n 1 | sed 's/masquerade to ://')"
      if [[ -n "$NFT_RANGE" ]]; then
        NFT_MIN="${NFT_RANGE%-*}"
        NFT_MAX="${NFT_RANGE#*-}"
        echo "FSE Switch WSLPOSTROUTING authorized range: ${NFT_MIN}-${NFT_MAX}"
        if [[ "$CUR_MIN" == "$NFT_MIN" && "$CUR_MAX" == "$NFT_MAX" ]]; then
          ok "Kernel ip_local_port_range (${CUR_MIN}-${CUR_MAX}) matches WSLPOSTROUTING (${NFT_MIN}-${NFT_MAX})."
        else
          fail "Port range mismatch! Kernel=${CUR_MIN}-${CUR_MAX}, FSE=${NFT_MIN}-${NFT_MAX}. Outbound TCP/UDP outside FSE range will be dropped!"
        fi
      else
        warn "Could not parse 'masquerade to :MIN-MAX' from WSLPOSTROUTING."
      fi
    fi
  else
    warn "Run with sudo to inspect 'nft list chain ip nat WSLPOSTROUTING' and verify FSE port range alignment."
  fi
else
  warn "'nft' command not found; skipping WSLPOSTROUTING check."
fi
echo

echo "=== 3. Scan sysctl Configs for Active ip_local_port_range Overrides ==="
SYSCTL_HITS=""
for target in /etc/sysctl.conf /etc/sysctl.d /usr/lib/sysctl.d /run/sysctl.d; do
  if [[ -e "$target" ]]; then
    hits="$(grep -rnE '^\s*net\.ipv4\.ip_local_port_range\s*=' "$target" 2>/dev/null || true)"
    if [[ -n "$hits" ]]; then
      SYSCTL_HITS+="${hits}"$'\n'
    fi
  fi
done

if [[ -n "$SYSCTL_HITS" ]]; then
  fail "Found active sysctl override(s) for net.ipv4.ip_local_port_range:"
  printf '%s' "$SYSCTL_HITS"
else
  ok "No active net.ipv4.ip_local_port_range override found in sysctl directories."
fi
echo

echo "=== 4. Linux Firewall (ufw) Status ==="
if command -v ufw >/dev/null 2>&1; then
  if [[ $EUID -eq 0 ]]; then
    UFW_STATUS="$(ufw status 2>/dev/null | head -n 1 || true)"
    echo "ufw: ${UFW_STATUS:-unknown}"
    if [[ "$UFW_STATUS" == *"active"* && "$UFW_STATUS" != *"inactive"* ]]; then
      warn "ufw is active. In WSL2 Mirrored mode, ufw nftables base-chains can conflict with WSLOUTPUT/ethX changes; consider 'sudo ufw disable'."
    else
      ok "ufw is inactive."
    fi
  else
    warn "Run with sudo to check 'ufw status'."
  fi
else
  ok "ufw not installed."
fi
echo

echo "=== 5. Policy Routing Tables 127 & 128 ==="
T127="$(ip route show table 127 2>/dev/null || true)"
T128="$(ip route show table 128 2>/dev/null || true)"
echo "table 127: ${T127:-<empty>}"
if [[ -n "$T128" ]]; then
  echo "table 128: ${T128} (hostAddressLoopback=true active)"
else
  echo "table 128: <not present> (normal when hostAddressLoopback is not active in [experimental])"
fi
echo

if [[ "$CHECK_NET" -eq 1 ]]; then
  echo "=== 6. Live Connectivity Checks (--net) ==="
  if getent ahostsv4 www.bing.com >/dev/null 2>&1; then
    ok "DNS resolution works (www.bing.com)."
  else
    fail "DNS resolution failed for www.bing.com."
  fi

  if ping -c 2 -W 2 223.5.5.5 >/dev/null 2>&1; then
    ok "ICMP ping to 223.5.5.5 succeeded."
  else
    warn "ICMP ping to 223.5.5.5 failed (may be blocked by upstream/network)."
  fi

  if curl -4 -IsS --max-time 5 https://www.bing.com >/dev/null 2>&1; then
    ok "HTTPS TCP check to https://www.bing.com succeeded."
  else
    fail "HTTPS TCP check to https://www.bing.com failed."
  fi

  if curl -4 -IsS --max-time 6 https://github.com >/dev/null 2>&1; then
    ok "HTTPS TCP check to https://github.com succeeded."
  else
    warn "HTTPS TCP check to https://github.com timed out/failed (expected if direct network cannot reach GitHub)."
  fi
  echo
fi

echo "=== Summary ==="
echo "PASS=${PASS}  WARN=${WARN}  FAIL=${FAIL}"
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
exit 0
