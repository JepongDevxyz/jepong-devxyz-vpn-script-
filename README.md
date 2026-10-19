# JepongDevxyz VPN Server Scripts

All-in-one VPN/tunnel server installer para sa Ubuntu 22.04/24.04 VPS.

## One-line install (Ubuntu)

```bash
curl -fsSL -o vpn-server-ubuntu.sh "https://raw.githubusercontent.com/JepongDevxyz/jepong-devxyz-vpn-script-/main/vpn-server-ubuntu.sh?cb=$(date +%s)" && chmod +x vpn-server-ubuntu.sh && sudo ./vpn-server-ubuntu.sh <domain> <ns-domain>
```

Halimbawa:

```bash
sudo ./vpn-server-ubuntu.sh vpn.example.com t.vpn.example.com
```

## Debian version

May `vpn-server-debian.sh` para sa Debian 11/12 — parehong features, parehong menu:

```bash
curl -fsSL -o vpn-server-debian.sh "https://raw.githubusercontent.com/JepongDevxyz/jepong-devxyz-vpn-script-/main/vpn-server-debian.sh?cb=$(date +%s)" && chmod +x vpn-server-debian.sh && sudo ./vpn-server-debian.sh <domain> <ns-domain>
```

> Beta pa ang Debian version — hindi pa nasusubukan sa tunay na Debian VPS. Ang Ubuntu version ang battle-tested.

## SSH password login

Default: ang password ay **`JepongDevxyz`** (auto-set sa user `ubuntu` pag install).
Gusto mo ng ibang password? Maglagay ng `SSH_PASSWORD`:

```bash
sudo SSH_PASSWORD='matibay-na-password-mo' ./vpn-server-ubuntu.sh vpn.example.com t.vpn.example.com
```

Bawal ang `:` sa password. Aktibo ang fail2ban kaya protektado laban sa brute force —
pero palitan mo agad ang default password ng malakas na password.

## Ano ang naka-install

| Service | Port |
|---------|------|
| SSH (OpenSSH + Dropbear) | 22, 109, 143 |
| OpenVPN (UDP) | 1194/udp |
| Xray: VLESS / VMess / Trojan (WebSocket + TLS) | 443 |
| UDP Custom (udp_custom) | 36712/udp (range 25000-26000) |
| SlowDNS (dnstt) | 53/udp |
| SSH WebSocket proxy | 8080 |
| nginx + Let's Encrypt SSL | 80, 443 |

Plus: BBR, UFW firewall, fail2ban. Ang `vpn-adduser` helper ay auto-install
sa `/usr/local/bin` — gumawa ng VPN users na may expiry:

```bash
sudo vpn-adduser <username> [araw]
```

## VPN Menu

Pagkatapos ng install, may interactive menu — tulad ng mga classic installer:

```bash
sudo vpn-menu
```

```
=======================================
    JEPONG DEVXYZ VPS SCRIPT
=======================================
  1) Create Account
  2) Check Account
  3) Delete Account
  4) VPN Details
  5) Service Status
  6) Restart Services
  0) Exit
=======================================
```

## Kailangan bago tumakbo

| Type | Name | Value |
|------|------|-------|
| A | `vpn.example.com` | IP ng VPS |
| A | `ns.vpn.example.com` | IP ng VPS |
| NS | `t.vpn.example.com` | `ns.vpn.example.com` |

Tingnan ang [VPN-README.md](VPN-README.md) para sa kumpletong detalye.
