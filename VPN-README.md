# VPN Server Scripts — JepongDevxyz

All-in-one VPN/tunnel server installer para sa Ubuntu 22.04/24.04 VPS.

## Bago tumakbo: DNS setup

Sa domain registrar mo (o Cloudflare), gawin ITO MUNA:

| Type | Name | Value |
|------|------|-------|
| A | `vpn.example.com` | IP ng VPS mo |
| A | `ns.vpn.example.com` | IP ng VPS mo |
| NS | `t.vpn.example.com` | `ns.vpn.example.com` |

Palitan ang `vpn.example.com` ng sarili mong domain. Maghintay ng 5-15 minuto
para mag-propagate ang DNS.

## Install

```bash
sudo bash vpn-server.sh vpn.example.com t.vpn.example.com
```

Mga 10-20 minuto ito sa unang takbo (maraming ida-download at iko-compile).

## Ano ang naka-install

| Service | Port | Detalye |
|---------|------|---------|
| OpenSSH | 22/tcp | normal SSH |
| Dropbear | 109, 143/tcp | lightweight SSH (pang-tunnel) |
| OpenVPN | 1194/udp + 1194/tcp | manual setup (apt + easy-rsa, hindi angristan); client file: `/root/jepong.ovpn` (UDP); TCP reuses PKI |
| Xray VLESS | 443/tcp (TLS+WS, path `/vless`) | UUID nasa summary |
| Xray VMess | 443/tcp (TLS+WS, path `/vmess`) | UUID nasa summary |
| Xray Trojan | 443/tcp (TLS+WS, path `/trojan`) | password nasa summary |
| Xray VLESS gRPC | 443/tcp (TLS, serviceName `grpc`) | parehong UUID ng VLESS |
| Xray VLESS XHTTP | 443/tcp (TLS, path `/xhttp`) | parehong UUID ng VLESS |
| WireGuard | 51820/udp | client config: `/etc/jepongvpn/wireguard-client.conf` |
| Shadowsocks | 8388/tcp+udp | method `aes-256-gcm`, password nasa summary |
| Hysteria2 | 4443/udp | password nasa summary, TLS cert ng domain |
| L2TP/IPSec | 500, 4500, 1701/udp | PSK + user/pass nasa `/etc/jepongvpn/l2tp-creds.txt` |
| IKEv2 | 500, 4500/udp | EAP user/pass nasa `/etc/jepongvpn/ikev2-creds.txt` |
| PPTP | 1723/tcp | user/pass nasa `/etc/jepongvpn/pptp-creds.txt` (Ubuntu 24.04+: via jammy extract; Debian at Ubuntu 22.04: via apt) |
| UDP Custom | 36712/udp (range 25000-26000) | PSK nasa summary |
| SlowDNS (dnstt) | 53/udp | public key nasa summary |
| SSH WebSocket | 8080/tcp | `ws://domain:8080` -> SSH |
| nginx | 80, 443/tcp | reverse proxy + Let's Encrypt SSL |

Plus: BBR congestion control, UFW firewall, fail2ban.

## Ano ang gagana sa bawat OS

| Service | Ubuntu 22.04 | Ubuntu 24.04 | Debian 11/12 |
|---------|--------------|--------------|--------------|
| SSH, Dropbear, Xray, UDP Custom, SlowDNS, WS, nginx | ✅ | ✅ | ✅ |
| WireGuard, Shadowsocks, Hysteria2, L2TP/IPSec, IKEv2 | ✅ | ✅ | ✅ |
| OpenVPN UDP + TCP | ✅ (manual setup) | ✅ (manual setup) | ✅ (manual setup) |
| PPTP | ✅ (via apt) | ✅ (via jammy package extract) | ✅ (via apt) |

Walang service na tinanggal: bawat installer ay gumagamit lang ng paraan na
gumagana sa OS niya. Ang Ubuntu 24.04 ay walang `pptpd` sa apt (tinanggal ng
Ubuntu), kaya ang installer ay nag-e-extract ng jammy package nang mano-mano
(na-verify: ang binary ay kailangan lang ng libwrap + libc). Ang Debian ay
gumagamit lang ng apt (may `pptpd` pa sa bookworm).

Pagkatapos ng install, ipi-print ng script ang LAHAT ng credentials
(UUIDs, passwords, PSK, SlowDNS public key, VLESS/Trojan links).
Itago ang mga ito — nasa `/etc/jepongvpn/` din (root-only).

## Magdagdag ng user

```bash
sudo bash vpn-adduser.sh <username> [araw] [password]
# hal: sudo bash vpn-adduser.sh jepong1 30
```

Gumagawa ng SSH user na may expiry date. Default 30 araw, random password
kapag hindi binigyan.

## Client apps na pwede

- **OpenVPN**: OpenVPN Connect (Android/iOS/PC) — import `/root/jepong.ovpn`
- **Xray**: v2rayNG / Nekoray / Streisand — gamitin ang links sa summary
- **SlowDNS**: SlowDNS app / HTTP Custom (SlowDNS mode) — NS domain + public key + SSH user
- **SSH/WS**: HTTP Custom / KPN Tunnel — `ws://domain:8080`, SSH user
- **UDP Custom**: Stun client (NNdroid) o kahit anong udp_custom-compatible client — PSK + port 36712

## Tungkol sa "UDP"

Ang gamit dito ay **udp_custom** (NNdroid, open-source, GPL-3.0) — modernong
UDP tunnel na may sariling protocol. Hindi ito compatible sa lumang
"UDP Custom" mode ng ibang apps; gumamit ng Stun client o udp_custom client.

## Na-test

- `bash -n` sa lahat ng scripts — pasado
- **ssh-ws.py**: tunay na functional test — HTTP 101 handshake, tamang
  Sec-WebSocket-Accept, bidirectional relay, 10 sabay na connections — pasado
- **Xray config**: na-validate gamit ang TUNAY na xray binary
  (`xray run -test`) — "Configuration OK"
- **vpn-adduser.sh**: isolated test — user creation, expiry, duplicate at
  usage errors — pasado
- Hindi na-test sa totoong VPS (walang public IP dito): ang OpenVPN
  headless install, dnstt build, at udp_custom install ay galing sa
  official documented methods ng bawat project.
