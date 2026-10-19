# JepongDevxyz VPN Server Scripts

All-in-one VPN/tunnel server installer para sa Ubuntu 22.04/24.04 VPS.

## One-line install

```bash
curl -fsSL -o vpn-server.sh https://raw.githubusercontent.com/JepongDevxyz/jepong-devxyz-vpn-script-/main/vpn-server.sh && chmod +x vpn-server.sh && sudo ./vpn-server.sh <domain> <ns-domain>
```

Halimbawa:

```bash
sudo ./vpn-server.sh vpn.example.com t.vpn.example.com
```

## SSH password login (optional)

Gusto mo ng user/pass sa Termius imbes na SSH key? Maglagay ng `SSH_PASSWORD`:

```bash
sudo SSH_PASSWORD='matibay-na-password-mo' ./vpn-server.sh vpn.example.com t.vpn.example.com
```

Bawal ang `:` sa password. Aktibo ang fail2ban kaya protektado laban sa brute force —
pero gumamit pa rin ng malakas na password.

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

## Kailangan bago tumakbo

| Type | Name | Value |
|------|------|-------|
| A | `vpn.example.com` | IP ng VPS |
| A | `ns.vpn.example.com` | IP ng VPS |
| NS | `t.vpn.example.com` | `ns.vpn.example.com` |

Tingnan ang [VPN-README.md](VPN-README.md) para sa kumpletong detalye.
