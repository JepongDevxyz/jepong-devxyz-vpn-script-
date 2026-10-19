#!/usr/bin/env bash
#
# vpn-server.sh — all-in-one VPN/tunnel server installer (JepongDevxyz)
#
# Target: fresh Ubuntu 22.04 / 24.04 VPS. Run as root:
#   sudo bash vpn-server.sh <domain> <ns-domain>
#
#   <domain>    main domain, A record -> VPS IP. Hal: vpn.example.com
#   <ns-domain> SlowDNS tunnel domain, kailangan ng NS record. Hal: t.vpn.example.com
#               DNS na kailangan BAGO tumakbo:
#                 A   ns.vpn.example.com  -> VPS_IP
#                 NS  t.vpn.example.com   -> ns.vpn.example.com
#
# Ini-install:
#   1. SSH — OpenSSH (22) + Dropbear (109, 143)
#   2. OpenVPN — UDP 1194 (angristan headless install)
#   3. Xray — VLESS/VMess/Trojan over WebSocket + TLS (443, nginx)
#   4. UDP — udp_custom server (UDP 36712, port range 25000-26000)
#   5. SlowDNS — dnstt server (UDP 53)
#   6. WebSocket — SSH-over-WS python proxy (8080)
#   + BBR, UFW firewall, fail2ban
#
set -euo pipefail

log()  { echo -e "\033[1;32m[+]\033[0m $*"; }
warn() { echo -e "\033[1;33m[!]\033[0m $*" >&2; }
die()  { echo -e "\033[1;31m[x]\033[0m $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "Patakbuhin as root: sudo bash vpn-server.sh <domain> <ns-domain>"
DOMAIN="${1:-}"; NSDOMAIN="${2:-}"
[ -n "$DOMAIN" ] && [ -n "$NSDOMAIN" ] || die "Usage: sudo bash vpn-server.sh <domain> <ns-domain>"

if [ -f /etc/os-release ]; then
  # shellcheck disable=SC1091
  . /etc/os-release
else
  die "Hindi Ubuntu ang OS na ito."
fi
[ "${ID:-}" = "ubuntu" ] || die "Ubuntu lang ang supported (nakita: ${ID:-unknown})."

export DEBIAN_FRONTEND=noninteractive
PUBIP="$(curl -fsSL --max-time 15 https://api.ipify.org 2>/dev/null || curl -fsSL --max-time 15 https://ifconfig.me 2>/dev/null || echo UNKNOWN)"
log "Domain: $DOMAIN | SlowDNS NS: $NSDOMAIN | VPS IP: $PUBIP"

# --- DNS pre-check (warning lang, hindi fatal) --------------------------------
if command -v dig >/dev/null 2>&1 || command -v getent >/dev/null 2>&1; then
  if ! getent hosts "$DOMAIN" >/dev/null 2>&1; then
    warn "$DOMAIN ay hindi pa nagre-resolve — siguraduhing may A record ito -> $PUBIP bago mag-certbot."
  fi
  if ! getent hosts "$NSDOMAIN" >/dev/null 2>&1; then
    warn "$NSDOMAIN ay hindi pa nagre-resolve — kailangan ng NS record para sa SlowDNS."
  fi
fi

HAS_SYSTEMD=0
if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then HAS_SYSTEMD=1; fi
svc() {
  if [ "$HAS_SYSTEMD" -eq 1 ]; then
    systemctl "$1" "$2" || warn "systemctl $1 $2 pumalya"
  else
    warn "walang systemd — skip: systemctl $1 $2"
  fi
}

# =============================================================================
log "Step 1/11: system update + essentials..."
# Preseed iptables-persistent BAGO i-install para hindi mag-prompt
echo "iptables-persistent iptables-persistent/autosave_v4 boolean true" | debconf-set-selections
echo "iptables-persistent iptables-persistent/autosave_v6 boolean true" | debconf-set-selections
apt-get update -qq
# Ayusin muna ang anumang sira/half-configured packages (karaniwang sanhi ng "held broken packages")
dpkg --configure -a 2>/dev/null || true
apt-get install -y -qq --fix-broken 2>/dev/null || true
# Ang upgrade ay hindi fatal — huwag patayin ang buong install kapag ito pumalya
apt-get upgrade -y -qq || warn "apt-get upgrade pumalya — tutuloy pa rin sa pag-install ng packages."
apt-get install -y -qq curl wget git python3 ufw fail2ban nginx certbot python3-certbot-nginx \
  dropbear openssh-server dnsutils iptables-persistent netfilter-persistent \
  || {
    warn "combined apt install pumalya — susubukan nang paisa-isa para hindi patayin ng isang package ang lahat."
    PKGS_ESSENTIAL="curl wget git python3 ufw fail2ban nginx certbot python3-certbot-nginx dropbear openssh-server iptables-persistent"
    PKGS_OPTIONAL="dnsutils netfilter-persistent"
    FAILED=""
    for p in $PKGS_ESSENTIAL; do
      apt-get install -y -qq "$p" || FAILED="$FAILED $p"
    done
    for p in $PKGS_OPTIONAL; do
      apt-get install -y -qq "$p" || warn "optional package '$p' hindi na-install — tutuloy pa rin."
    done
    [ -z "$FAILED" ] || die "Hindi na-install ang mga essential package:$FAILED."
  }

# =============================================================================
log "Step 2/11: palayain ang port 53 (disable systemd-resolved stub)..."
systemctl disable --now systemd-resolved 2>/dev/null || true
rm -f /etc/resolv.conf
printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > /etc/resolv.conf

# =============================================================================
log "Step 3/11: SSH — OpenSSH (22) + Dropbear (109, 143)..."
cp -n /etc/default/dropbear /etc/default/dropbear.bak 2>/dev/null || true
printf 'NO_START=0\nDROPBEAR_PORT=109\nDROPBEAR_EXTRA_ARGS="-p 143"\nDROPBEAR_BANNER=""\nDROPBEAR_RSAKEY="/etc/dropbear/dropbear_rsa_host_key"\nDROPBEAR_DSSKEY="/etc/dropbear/dropbear_dss_host_key"\nDROPBEAR_ECDSAKEY="/etc/dropbear/dropbear_ecdsa_host_key"\nDROPBEAR_RECEIVE_WINDOW=65536\n' > /etc/default/dropbear
svc enable ssh; svc restart ssh
svc enable dropbear; svc restart dropbear

# --- Optional: SSH password login (kapag may SSH_PASSWORD env var) ---
# Hal: sudo SSH_PASSWORD='matibay-na-password' ./vpn-server.sh <domain> <ns-domain>
if [ -n "${SSH_PASSWORD:-}" ]; then
  SSH_USER="${SUDO_USER:-ubuntu}"
  id "$SSH_USER" >/dev/null 2>&1 || SSH_USER="ubuntu"
  case "$SSH_PASSWORD" in
    *:* ) warn "Ang password ay hindi pwedeng may ':' — nilaktawan ang password setup."; SSH_PASSWORD="" ;;
  esac
  if [ -n "${SSH_PASSWORD:-}" ]; then
    if echo "$SSH_USER:$SSH_PASSWORD" | chpasswd; then
      log "Password na-set para sa user '$SSH_USER'."
    else
      warn "chpasswd pumalya para sa '$SSH_USER'."
    fi
    # sshd: first-obtained value wins — 00- drop-in para ma-override ang cloudimg default (PasswordAuthentication no)
    printf 'PasswordAuthentication yes\n' > /etc/ssh/sshd_config.d/00-jepongvpn-password.conf
    svc restart ssh
    log "SSH password login ENABLED (user: $SSH_USER). Gumamit ng malakas na password — aktibo ang fail2ban."
  fi
else
  log "SSH password login: skipped (walang SSH_PASSWORD env var)."
fi

# =============================================================================
log "Step 4/11: OpenVPN (UDP 1194)..."
if [ ! -f /etc/openvpn/server.conf ]; then
  curl -fsSL -o /root/openvpn-install.sh \
    https://raw.githubusercontent.com/angristan/openvpn-install/master/openvpn-install.sh
  chmod +x /root/openvpn-install.sh
  AUTO_INSTALL=y APPROVE_INSTALL=y APPROVE_IP=y IPV6_SUPPORT=n \
    PORT_CHOICE=1 PROTOCOL_CHOICE=1 DNS=1 COMPRESSION_ENABLED=n CUSTOMIZE_ENC=n \
    CLIENT=jepong PASS=1 ENDPOINT="$DOMAIN" bash /root/openvpn-install.sh
  log "OpenVPN client file: /root/jepong.ovpn"
else
  log "OpenVPN naka-install na — skip."
fi

# =============================================================================
log "Step 5/11: Xray (VLESS/VMess/Trojan over WebSocket)..."
if ! command -v xray >/dev/null 2>&1; then
  bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
fi
UUID_VLESS="$(cat /proc/sys/kernel/random/uuid)"
UUID_VMESS="$(cat /proc/sys/kernel/random/uuid)"
TROJAN_PASS="$(python3 -c 'import secrets; print(secrets.token_hex(16))')"
python3 - "$UUID_VLESS" "$UUID_VMESS" "$TROJAN_PASS" <<'PYEOF' > /usr/local/etc/xray/config.json
import json, sys
uuid_vless, uuid_vmess, trojan_pass = sys.argv[1], sys.argv[2], sys.argv[3]
def ws_inbound(port, protocol, clients, path):
    settings = {"clients": clients}
    if protocol == "vless":
        settings["decryption"] = "none"
    return {
        "port": port, "listen": "127.0.0.1", "protocol": protocol,
        "settings": settings,
        "streamSettings": {"network": "ws", "wsSettings": {"path": path}},
    }
config = {
    "log": {"loglevel": "warning"},
    "inbounds": [
        ws_inbound(10001, "vless", [{"id": uuid_vless}], "/vless"),
        ws_inbound(10002, "vmess", [{"id": uuid_vmess, "alterId": 0}], "/vmess"),
        ws_inbound(10003, "trojan", [{"password": trojan_pass}], "/trojan"),
    ],
    "outbounds": [{"protocol": "freedom"}],
}
print(json.dumps(config, indent=2))
PYEOF
chmod 644 /usr/local/etc/xray/config.json
if command -v xray >/dev/null 2>&1; then
  if xray run -test -c /usr/local/etc/xray/config.json >/dev/null 2>&1; then
    log "xray config valid."
  else
    warn "xray config test pumalya — itutuloy pa rin, i-check ang /usr/local/etc/xray/config.json."
  fi
fi
svc enable xray; svc restart xray
if [ "$HAS_SYSTEMD" -eq 1 ]; then
  systemctl is-active --quiet xray || die "xray hindi tumatakbo — tingnan: journalctl -u xray"
fi
mkdir -p /etc/jepongvpn
printf '%s\n%s\n%s\n' "$UUID_VLESS" "$UUID_VMESS" "$TROJAN_PASS" > /etc/jepongvpn/xray-creds.txt
chmod 600 /etc/jepongvpn/xray-creds.txt
printf '%s\n' "$DOMAIN" > /etc/jepongvpn/domain.txt
printf '%s\n' "$NSDOMAIN" > /etc/jepongvpn/nsdomain.txt
chmod 600 /etc/jepongvpn/domain.txt /etc/jepongvpn/nsdomain.txt

# =============================================================================
log "Step 6/11: nginx + Let's Encrypt SSL para sa $DOMAIN..."
cat > /etc/nginx/sites-available/vpn <<'NGEOF'
server {
    listen 80;
    server_name @DOMAIN@;
    location / { return 301 https://$host$request_uri; }
}
NGEOF
sed -i "s/@DOMAIN@/$DOMAIN/g" /etc/nginx/sites-available/vpn
ln -sf /etc/nginx/sites-available/vpn /etc/nginx/sites-enabled/vpn
rm -f /etc/nginx/sites-enabled/default
nginx -t
svc restart nginx
certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos \
  --register-unsafely-without-email --redirect \
  || die "certbot pumalya — siguraduhing ang A record ng $DOMAIN ay -> $PUBIP at bukas ang port 80."
# Full vhost: WS proxy paths para sa Xray
cat > /etc/nginx/sites-available/vpn <<'NGEOF'
server {
    listen 80;
    server_name @DOMAIN@;
    location / { return 301 https://$host$request_uri; }
}
server {
    listen 443 ssl;
    server_name @DOMAIN@;
    ssl_certificate /etc/letsencrypt/live/@DOMAIN@/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/@DOMAIN@/privkey.pem;

    location = /vless {
        proxy_pass http://127.0.0.1:10001;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
    }
    location = /vmess {
        proxy_pass http://127.0.0.1:10002;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
    }
    location = /trojan {
        proxy_pass http://127.0.0.1:10003;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
    }
    location / { return 404; }
}
NGEOF
sed -i "s/@DOMAIN@/$DOMAIN/g" /etc/nginx/sites-available/vpn
nginx -t || die "nginx config may mali."
svc reload nginx || svc restart nginx

# =============================================================================
log "Step 7/11: WebSocket SSH proxy (port 8080)..."
cat > /usr/local/bin/ssh-ws.py <<'PYEOF'
#!/usr/bin/env python3
"""SSH-over-WebSocket proxy: HTTP Upgrade -> raw TCP bridge sa SSH (127.0.0.1:22)."""
import os, socket, threading, base64, hashlib

LISTEN = ("0.0.0.0", int(os.environ.get("SSH_WS_PORT", "8080")))
TARGET = (os.environ.get("SSH_WS_TARGET_HOST", "127.0.0.1"),
          int(os.environ.get("SSH_WS_TARGET_PORT", "22")))
GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

def relay(a, b):
    try:
        while True:
            d = a.recv(65536)
            if not d:
                break
            b.sendall(d)
    except OSError:
        pass
    finally:
        for s in (a, b):
            try:
                s.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            s.close()

def handle(c):
    try:
        req = b""
        while b"\r\n\r\n" not in req:
            chunk = c.recv(4096)
            if not chunk:
                c.close()
                return
            req += chunk
            if len(req) > 16384:
                c.close()
                return
        key = ""
        for h in req.decode("latin1").split("\r\n"):
            if h.lower().startswith("sec-websocket-key:"):
                key = h.split(":", 1)[1].strip()
        accept = base64.b64encode(hashlib.sha1((key + GUID).encode()).digest()).decode()
        c.sendall(("HTTP/1.1 101 Switching Protocols\r\n"
                   "Upgrade: websocket\r\n"
                   "Connection: Upgrade\r\n"
                   f"Sec-WebSocket-Accept: {accept}\r\n\r\n").encode())
        up = socket.create_connection(TARGET, timeout=10)
        threading.Thread(target=relay, args=(c, up), daemon=True).start()
        relay(up, c)
    except OSError:
        try:
            c.close()
        except OSError:
            pass

def main():
    s = socket.socket()
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(LISTEN)
    s.listen(128)
    while True:
        c, _ = s.accept()
        threading.Thread(target=handle, args=(c,), daemon=True).start()

if __name__ == "__main__":
    main()
PYEOF
chmod +x /usr/local/bin/ssh-ws.py
cat > /etc/systemd/system/ssh-ws.service <<'SVCEOF'
[Unit]
Description=SSH WebSocket proxy (8080 -> 22)
After=network.target
[Service]
Type=simple
ExecStart=/usr/bin/python3 /usr/local/bin/ssh-ws.py
Restart=always
RestartSec=3
[Install]
WantedBy=multi-user.target
SVCEOF
if [ "$HAS_SYSTEMD" -eq 1 ]; then systemctl daemon-reload; fi
svc enable ssh-ws; svc start ssh-ws

# =============================================================================
log "Step 8/11: SlowDNS / dnstt (UDP 53)..."
if ! command -v /usr/local/bin/dnstt-server >/dev/null 2>&1 && [ ! -x /usr/local/bin/dnstt-server ]; then
  # Go (official tarball, pinakabagong stable)
  GO_FILE="$(curl -fsSL https://go.dev/dl/?mode=json | python3 -c "
import json, sys
d = json.load(sys.stdin)
v = [x for x in d if x.get('stable')][0]
fs = [f['filename'] for f in v['files'] if f['os']=='linux' and f['arch']=='amd64' and f['kind']=='archive']
print(fs[0])")"
  log "Go tarball: $GO_FILE"
  curl -fsSL -o "/tmp/$GO_FILE" "https://go.dev/dl/$GO_FILE"
  rm -rf /usr/local/go
  tar -C /usr/local -xzf "/tmp/$GO_FILE"
  rm -f "/tmp/$GO_FILE"
  echo 'export PATH=$PATH:/usr/local/go/bin' > /etc/profile.d/go.sh
  # dnstt source + build
  rm -rf /opt/dnstt
  git clone https://www.bamsoftware.com/git/dnstt.git /opt/dnstt
  (cd /opt/dnstt/dnstt-server && CGO_ENABLED=0 /usr/local/go/bin/go build -o /usr/local/bin/dnstt-server .)
  chmod +x /usr/local/bin/dnstt-server
fi
mkdir -p /etc/dnstt
if [ ! -f /etc/dnstt/server.key ]; then
  /usr/local/bin/dnstt-server -gen-key -privkey-file /etc/dnstt/server.key -pubkey-file /etc/dnstt/server.pub
  chmod 600 /etc/dnstt/server.key
fi
cat > /etc/systemd/system/dnstt.service <<SVCEOF
[Unit]
Description=DNSTT SlowDNS server (UDP 53)
After=network.target
[Service]
Type=simple
ExecStart=/usr/local/bin/dnstt-server -udp :53 -privkey-file /etc/dnstt/server.key $NSDOMAIN 127.0.0.1:22
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
SVCEOF
if [ "$HAS_SYSTEMD" -eq 1 ]; then systemctl daemon-reload; fi
svc enable dnstt; svc restart dnstt
DNSTT_PUB="$(cat /etc/dnstt/server.pub)"

# =============================================================================
log "Step 9/11: UDP Custom server (udp_custom)..."
# I-build mula sa source — walang GitHub releases ang udp_custom repo (404 sa install.sh).
UDP_OK=0
if [ ! -x /usr/local/bin/udp_custom ]; then
  if rm -rf /opt/udp_custom \
    && git clone --depth 1 https://github.com/NNdroid/udp_custom.git /opt/udp_custom \
    && (cd /opt/udp_custom && CGO_ENABLED=0 /usr/local/go/bin/go build -o /usr/local/bin/udp_custom .) \
    && chmod +x /usr/local/bin/udp_custom; then
    log "udp_custom na-build mula sa source."
    UDP_OK=1
  else
    warn "udp_custom build pumalya — lalaktawan ang UDP Custom (ibang services OK)."
  fi
else
  UDP_OK=1
fi
if [ "$UDP_OK" -eq 1 ]; then
mkdir -p /etc/udp_custom
cat > /etc/systemd/system/udp_custom.service <<'SVCEOF'
[Unit]
Description=udp_custom UDPCustom Stream Tunnel Server
After=network.target
[Service]
Type=simple
User=root
WorkingDirectory=/etc/udp_custom
ExecStart=/usr/local/bin/udp_custom -c /etc/udp_custom/config.server.json
Restart=always
RestartSec=3s
LimitNOFILE=1048576
[Install]
WantedBy=multi-user.target
SVCEOF
if [ "$HAS_SYSTEMD" -eq 1 ]; then systemctl daemon-reload; fi
svc enable udp_custom
UDP_PSK="$(python3 -c 'import secrets; print(secrets.token_hex(16))')"
python3 - "$DOMAIN" "$UDP_PSK" <<'PYEOF' > /etc/udp_custom/config.server.json
import json, sys
domain, psk = sys.argv[1], sys.argv[2]
config = {
    "mode": "server",
    "listen": ":36712",
    "port_range": "25000-26000",
    "host": domain,
    "origdst": True,
    "sendsock_max": 1024,
    "target": "tcp://127.0.0.1:22",
    "allowed_targets": ["tcp://127.0.0.1:*"],
    "passwords": [psk],
    "receive_sockets": 4,
    "fec": True,
    "max_pkt": 1450,
    "magic": "UDPC",
    "privkey": "",
    "log_level": "info",
}
print(json.dumps(config, indent=2))
PYEOF
svc restart udp_custom
# DNAT: buong port range -> listen port (kailangan ng clients na nag-spread)
iptables -t nat -C PREROUTING -p udp --dport 25000:26000 -j REDIRECT --to-ports 36712 2>/dev/null \
  || iptables -t nat -A PREROUTING -p udp --dport 25000:26000 -j REDIRECT --to-ports 36712
netfilter-persistent save >/dev/null 2>&1 || iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
printf '%s\n' "$UDP_PSK" > /etc/jepongvpn/udp-psk.txt
chmod 600 /etc/jepongvpn/udp-psk.txt
fi # UDP_OK

# =============================================================================
log "Step 10/11: BBR congestion control..."
if ! grep -q 'net.ipv4.tcp_congestion_control=bbr' /etc/sysctl.conf 2>/dev/null; then
  printf '\nnet.core.default_qdisc=fq\nnet.ipv4.tcp_congestion_control=bbr\n' >> /etc/sysctl.conf
fi
sysctl -p >/dev/null 2>&1 || sysctl --system >/dev/null 2>&1 || true

# =============================================================================
log "Step 11/11: UFW firewall..."
if ufw --force reset >/dev/null 2>&1; then
  ufw default deny incoming >/dev/null
  ufw default allow outgoing >/dev/null
  ufw allow 22/tcp >/dev/null
  ufw allow 109/tcp >/dev/null
  ufw allow 143/tcp >/dev/null
  ufw allow 80/tcp >/dev/null
  ufw allow 443/tcp >/dev/null
  ufw allow 8080/tcp >/dev/null
  ufw allow 1194/udp >/dev/null
  ufw allow 53/udp >/dev/null
  ufw allow 36712/udp >/dev/null
  ufw allow 25000:26000/udp >/dev/null
  if ufw --force enable; then log "UFW active."; else warn "UFW enable pumalya."; fi
else
  warn "UFW hindi gumana dito."
fi
svc enable fail2ban; svc start fail2ban

# vpn-adduser + vpn-menu helpers — kunin mula sa GitHub repo para isang install lang
HELPER_BASE="https://raw.githubusercontent.com/JepongDevxyz/jepong-devxyz-vpn-script-/main"
for h in vpn-adduser vpn-menu; do
  if curl -fsSL -o "/usr/local/bin/$h" "$HELPER_BASE/$h.sh"; then
    chmod +x "/usr/local/bin/$h"
    log "$h installed."
  else
    warn "hindi na-download ang $h helper mula sa $HELPER_BASE/$h.sh"
  fi
done

# =============================================================================
echo ""
echo "=============================================================="
echo "  VPN SERVER TAPOS. Heto ang detalye:"
echo "=============================================================="
echo "  Domain........: $DOMAIN ($PUBIP)"
echo ""
echo "  [SSH]"
echo "    OpenSSH.....: port 22"
echo "    Dropbear....: port 109, 143"
if [ -n "${SSH_PASSWORD:-}" ]; then
echo "    Password....: ENABLED (user: ${SUDO_USER:-ubuntu})"
else
echo "    Password....: key-only (maglagay ng SSH_PASSWORD env var para i-enable)"
fi
echo ""
echo "  [OpenVPN]"
echo "    UDP 1194, client file: /root/jepong.ovpn"
echo ""
echo "  [Xray]  (TLS, port 443)"
echo "    VLESS UUID..: $UUID_VLESS"
echo "    VLESS link..: vless://$UUID_VLESS@$DOMAIN:443?path=%2Fvless&security=tls&encryption=none&type=ws#$DOMAIN-vless"
echo "    VMess UUID..: $UUID_VMESS"
echo "    Trojan pass.: $TROJAN_PASS"
echo "    Trojan link.: trojan://$TROJAN_PASS@$DOMAIN:443?path=%2Ftrojan&security=tls&type=ws#$DOMAIN-trojan"
echo ""
echo "  [UDP Custom]"
if [ -f /etc/jepongvpn/udp-psk.txt ]; then
echo "    Port 36712 (range 25000-26000), PSK: $(cat /etc/jepongvpn/udp-psk.txt)"
else
echo "    HINDI NA-INSTALL (build pumalya) — ibang services OK"
fi
echo ""
echo "  [SlowDNS]"
echo "    NS domain...: $NSDOMAIN (UDP 53)"
echo "    Public key..: $DNSTT_PUB"
echo ""
echo "  [WebSocket SSH]"
echo "    ws://$DOMAIN:8080  ->  SSH 127.0.0.1:22"
echo "=============================================================="
echo "  Magdagdag ng SSH user:  sudo vpn-adduser <user> <araw>"
echo "  Tandaan: itago ang mga credentials sa itaas!"
echo "=============================================================="
