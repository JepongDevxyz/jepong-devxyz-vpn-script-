#!/usr/bin/env bash
#
# vpn-server-ubuntu.sh — all-in-one VPN/tunnel server installer (JepongDevxyz)
#
# Target: fresh Ubuntu 22.04 / 24.04 VPS. Run as root:
#   sudo bash vpn-server-ubuntu.sh <domain> <ns-domain>
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

[ "$(id -u)" -eq 0 ] || die "Patakbuhin as root: sudo bash vpn-server-ubuntu.sh <domain> <ns-domain>"
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

# StrongSwan service name: "strongswan-starter" sa Ubuntu 24.04+/Debian 12+, "strongswan" sa luma
SS_SVC="strongswan"
if command -v systemctl >/dev/null 2>&1; then
  if systemctl list-unit-files 2>/dev/null | grep -q "^strongswan-starter.service"; then
    SS_SVC="strongswan-starter"
  fi
fi

# =============================================================================
log "Step 1/18: system update + essentials..."
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

# Swap para sa maliliit na VPS (<2GB RAM, walang swap): kailangan ng Go builds (dnstt Step 8, udp_custom Step 9).
# Kung walang swap, ang Go compiler ay papatayin ng OOM killer sa 512MB box (proven 2026-10-24 sa Ubuntu).
if [ ! -f /swapfile ]; then
  SWAP_TOTAL="$(free -m 2>/dev/null | awk '/^Swap:/ {print $2}')"
  MEM_TOTAL="$(free -m 2>/dev/null | awk '/^Mem:/ {print $2}')"
  if [ "${SWAP_TOTAL:-1}" = "0" ] && [ -n "$MEM_TOTAL" ] && [ "$MEM_TOTAL" -lt 2048 ]; then
    log "Maliit na RAM (${MEM_TOTAL}MB) at walang swap — gumagawa ng 1GB swapfile para hindi ma-OOM ang Go builds..."
    fallocate -l 1G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=1024 status=none 2>/dev/null || warn "swapfile hindi magawa."
    chmod 600 /swapfile 2>/dev/null || true
    mkswap /swapfile >/dev/null 2>&1 || true
    swapon /swapfile 2>/dev/null || warn "swapon pumalya."
    grep -q "^/swapfile" /etc/fstab 2>/dev/null || echo "/swapfile none swap sw 0 0" >> /etc/fstab
  fi
fi

# =============================================================================
log "Step 2/18: palayain ang port 53 (disable systemd-resolved stub)..."
systemctl disable --now systemd-resolved 2>/dev/null || true
rm -f /etc/resolv.conf
printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > /etc/resolv.conf
# Ayusin ang sudo "unable to resolve host" warning (nawala ang cloud DNS sa resolv.conf)
grep -q "$(hostname)" /etc/hosts 2>/dev/null || echo "127.0.0.1 $(hostname)" >> /etc/hosts

# =============================================================================
log "Step 3/18: SSH — OpenSSH (22) + Dropbear (109, 143)..."
cp -n /etc/default/dropbear /etc/default/dropbear.bak 2>/dev/null || true
printf 'NO_START=0\nDROPBEAR_PORT=109\nDROPBEAR_EXTRA_ARGS="-p 143"\nDROPBEAR_BANNER=""\nDROPBEAR_RSAKEY="/etc/dropbear/dropbear_rsa_host_key"\nDROPBEAR_DSSKEY="/etc/dropbear/dropbear_dss_host_key"\nDROPBEAR_ECDSAKEY="/etc/dropbear/dropbear_ecdsa_host_key"\nDROPBEAR_RECEIVE_WINDOW=65536\n' > /etc/default/dropbear
svc enable ssh; svc restart ssh
svc enable dropbear; svc restart dropbear

# --- SSH password login (default: JepongDevxyz; o maglagay ng SSH_PASSWORD env var) ---
# Hal: sudo SSH_PASSWORD='matibay-na-password' ./vpn-server-ubuntu.sh <domain> <ns-domain>
SSH_PASSWORD_IS_DEFAULT=0
if [ -z "${SSH_PASSWORD:-}" ]; then
  SSH_PASSWORD="JepongDevxyz"
  SSH_PASSWORD_IS_DEFAULT=1
fi
if [ -n "$SSH_PASSWORD" ]; then
  SSH_USER="${SUDO_USER:-ubuntu}"
  id "$SSH_USER" >/dev/null 2>&1 || SSH_USER="ubuntu"
  case "$SSH_PASSWORD" in
    *:* ) warn "Ang password ay hindi pwedeng may ':' — nilaktawan ang password setup."; SSH_PASSWORD="" ;;
  esac
  if [ -n "$SSH_PASSWORD" ]; then
    if echo "$SSH_USER:$SSH_PASSWORD" | chpasswd; then
      log "Password na-set para sa user '$SSH_USER'."
    else
      warn "chpasswd pumalya para sa '$SSH_USER'."
    fi
    # sshd: first-obtained value wins — 00- drop-in para ma-override ang cloudimg default (PasswordAuthentication no)
    printf 'PasswordAuthentication yes\n' > /etc/ssh/sshd_config.d/00-jepongvpn-password.conf
    svc restart ssh
    log "SSH password login ENABLED (user: $SSH_USER)."
    if [ "$SSH_PASSWORD_IS_DEFAULT" -eq 1 ]; then
      warn "DEFAULT password ang gamit (JepongDevxyz) — palitan mo agad ng malakas na password! Aktibo ang fail2ban."
    fi
  fi
fi

# =============================================================================
log "Step 4/18: OpenVPN (UDP 1194, manual setup)..."
if [ -f /etc/openvpn/server/server.conf ] || [ -f /etc/openvpn/server.conf ]; then
  log "OpenVPN naka-install na — skip."
else
  apt-get install -y -qq openvpn easy-rsa 2>/dev/null || warn "openvpn/easy-rsa hindi ma-install."
  if command -v openvpn >/dev/null 2>&1; then
    mkdir -p /etc/openvpn/server /etc/openvpn/easy-rsa
    if [ ! -f /etc/openvpn/server/ca.crt ]; then
      if [ -d /usr/share/easy-rsa ]; then
        cp -r /usr/share/easy-rsa/* /etc/openvpn/easy-rsa/ 2>/dev/null || true
      fi
      if [ ! -f /etc/openvpn/easy-rsa/easyrsa ]; then
        EASYRSA_TGZ="$(curl -fsSL https://api.github.com/repos/OpenVPN/easy-rsa/releases/latest 2>/dev/null | grep -o 'https://[^"]*EasyRSA-3[^"]*\.tgz' | head -1)"
        if [ -n "$EASYRSA_TGZ" ]; then
          curl -fsSL -o /tmp/easyrsa.tgz "$EASYRSA_TGZ" && tar -xzf /tmp/easyrsa.tgz -C /tmp \
            && cp -r /tmp/EasyRSA-*/easyrsa3/* /etc/openvpn/easy-rsa/ 2>/dev/null \
            && log "easy-rsa na-download." || warn "easy-rsa download pumalya."
        fi
      fi
      if [ -f /etc/openvpn/easy-rsa/easyrsa ]; then
        cd /etc/openvpn/easy-rsa || warn "hindi makapasok sa easy-rsa dir."
        ./easyrsa init-pki >/dev/null 2>&1 || true
        ./easyrsa --batch build-ca nopass >/dev/null 2>&1 || true
        ./easyrsa --batch build-server-full server nopass >/dev/null 2>&1 || true
        ./easyrsa --batch build-client-full jepong nopass >/dev/null 2>&1 || true
        ./easyrsa --batch gen-dh >/dev/null 2>&1 || true
        openvpn --genkey secret /etc/openvpn/server/ta.key 2>/dev/null || true
        cp pki/ca.crt pki/issued/server.crt pki/private/server.key pki/dh.pem /etc/openvpn/server/ 2>/dev/null || true
        cd / || true
        log "OpenVPN PKI nalikha."
      fi
    fi
    if [ -f /etc/openvpn/server/ca.crt ]; then
      cat > /etc/openvpn/server/server.conf <<OVPN_EOF
port 1194
proto udp
dev tun
ca /etc/openvpn/server/ca.crt
cert /etc/openvpn/server/server.crt
key /etc/openvpn/server/server.key
dh /etc/openvpn/server/dh.pem
topology subnet
server 10.8.0.0 255.255.255.0
push "redirect-gateway def1 bypass-dhcp"
push "dhcp-option DNS 1.1.1.1"
push "dhcp-option DNS 8.8.8.8"
keepalive 10 120
cipher AES-256-GCM
persist-key
persist-tun
status /var/log/openvpn-status.log
verb 3
explicit-exit-notify 1
tls-auth /etc/openvpn/server/ta.key 0
OVPN_EOF
      {
        echo "client"
        echo "dev tun"
        echo "proto udp"
        echo "remote $DOMAIN 1194"
        echo "resolv-retry infinite"
        echo "nobind"
        echo "persist-key"
        echo "persist-tun"
        echo "remote-cert-tls server"
        echo "cipher AES-256-GCM"
        echo "verb 3"
        echo "key-direction 1"
        echo "<ca>"
        cat /etc/openvpn/server/ca.crt
        echo "</ca>"
        echo "<cert>"
        cat /etc/openvpn/easy-rsa/pki/issued/jepong.crt
        echo "</cert>"
        echo "<key>"
        cat /etc/openvpn/easy-rsa/pki/private/jepong.key
        echo "</key>"
        echo "<tls-auth>"
        cat /etc/openvpn/server/ta.key
        echo "</tls-auth>"
      } > /root/jepong.ovpn
      grep -q 'net.ipv4.ip_forward=1' /etc/sysctl.conf 2>/dev/null || echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
      sysctl -p >/dev/null 2>&1 || true
      iptables -t nat -C POSTROUTING -s 10.8.0.0/24 -j MASQUERADE 2>/dev/null \
        || iptables -t nat -A POSTROUTING -s 10.8.0.0/24 -j MASQUERADE
      iptables -t nat -C POSTROUTING -s 10.9.0.0/24 -j MASQUERADE 2>/dev/null \
        || iptables -t nat -A POSTROUTING -s 10.9.0.0/24 -j MASQUERADE
      netfilter-persistent save >/dev/null 2>&1 || true
      svc enable openvpn-server@server; svc start openvpn-server@server
      log "OpenVPN UDP OK (1194/udp, client: /root/jepong.ovpn)."
    else
      warn "OpenVPN manual setup pumalya (walang ca.crt)."
    fi
  else
    warn "openvpn binary wala pa rin pagkatapos ng apt install."
  fi
fi

# =============================================================================
log "Step 5/18: Xray (VLESS/VMess/Trojan over WebSocket)..."
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
def grpc_inbound(port, protocol, clients, service):
    settings = {"clients": clients}
    if protocol == "vless":
        settings["decryption"] = "none"
    return {
        "port": port, "listen": "127.0.0.1", "protocol": protocol,
        "settings": settings,
        "streamSettings": {"network": "grpc", "grpcSettings": {"serviceName": service}},
    }
def xhttp_inbound(port, protocol, clients, path):
    settings = {"clients": clients}
    if protocol == "vless":
        settings["decryption"] = "none"
    return {
        "port": port, "listen": "127.0.0.1", "protocol": protocol,
        "settings": settings,
        "streamSettings": {"network": "xhttp", "xhttpSettings": {"path": path}},
    }
config = {
    "log": {"loglevel": "warning"},
    "inbounds": [
        ws_inbound(10001, "vless", [{"id": uuid_vless}], "/vless"),
        ws_inbound(10002, "vmess", [{"id": uuid_vmess, "alterId": 0}], "/vmess"),
        ws_inbound(10003, "trojan", [{"password": trojan_pass}], "/trojan"),
        grpc_inbound(10004, "vless", [{"id": uuid_vless}], "grpc"),
        xhttp_inbound(10005, "vless", [{"id": uuid_vless}], "/xhttp"),
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
log "Step 6/18: nginx + Let's Encrypt SSL para sa $DOMAIN..."
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
    location /grpc {
        grpc_pass grpc://127.0.0.1:10004;
    }
    location = /xhttp {
        proxy_pass http://127.0.0.1:10005;
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
log "Step 7/18: WebSocket SSH proxy (port 8080)..."
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
log "Step 8/18: SlowDNS / dnstt (UDP 53)..."
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
log "Step 9/18: UDP Custom server (udp_custom)..."
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
log "Step 10/18: BBR congestion control..."
if ! grep -q 'net.ipv4.tcp_congestion_control=bbr' /etc/sysctl.conf 2>/dev/null; then
  printf '\nnet.core.default_qdisc=fq\nnet.ipv4.tcp_congestion_control=bbr\n' >> /etc/sysctl.conf
fi
sysctl -p >/dev/null 2>&1 || sysctl --system >/dev/null 2>&1 || true

# =============================================================================
log "Step 11/18: WireGuard (UDP 51820)..."
apt-get install -y -qq wireguard 2>/dev/null || warn "wireguard package hindi ma-install."
if command -v wg >/dev/null 2>&1; then
  mkdir -p /etc/wireguard
  if [ ! -f /etc/wireguard/server.key ]; then
    wg genkey | tee /etc/wireguard/server.key | wg pubkey > /etc/wireguard/server.pub
    chmod 600 /etc/wireguard/server.key
  fi
  WG_PRIV="$(cat /etc/wireguard/server.key)"
  WG_PUB="$(cat /etc/wireguard/server.pub)"
  if [ ! -f /etc/wireguard/client.key ]; then
    wg genkey | tee /etc/wireguard/client.key | wg pubkey > /etc/wireguard/client.pub
    chmod 600 /etc/wireguard/client.key
  fi
  WG_CLI_PRIV="$(cat /etc/wireguard/client.key)"
  WG_CLI_PUB="$(cat /etc/wireguard/client.pub)"
  grep -q 'net.ipv4.ip_forward=1' /etc/sysctl.conf 2>/dev/null || echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
  sysctl -p >/dev/null 2>&1 || true
  cat > /etc/wireguard/wg0.conf <<WGEOF
[Interface]
PrivateKey = $WG_PRIV
Address = 10.7.0.1/24
ListenPort = 51820
PostUp = iptables -A FORWARD -i %i -j ACCEPT; iptables -t nat -A POSTROUTING -s 10.7.0.0/24 -j MASQUERADE
PostDown = iptables -D FORWARD -i %i -j ACCEPT; iptables -t nat -D POSTROUTING -s 10.7.0.0/24 -j MASQUERADE
[Peer]
PublicKey = $WG_CLI_PUB
AllowedIPs = 10.7.0.2/32
WGEOF
  chmod 600 /etc/wireguard/wg0.conf
  cat > /etc/jepongvpn/wireguard-client.conf <<WGEOF
[Interface]
PrivateKey = $WG_CLI_PRIV
Address = 10.7.0.2/24
DNS = 1.1.1.1
[Peer]
PublicKey = $WG_PUB
Endpoint = $DOMAIN:51820
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
WGEOF
  chmod 600 /etc/jepongvpn/wireguard-client.conf
  svc enable wg-quick@wg0; svc start wg-quick@wg0
  log "WireGuard OK (51820/udp)."
else
  warn "WireGuard hindi na-install (walang wg binary)."
fi

# =============================================================================
log "Step 12/18: Shadowsocks (8388)..."
apt-get install -y -qq shadowsocks-libev 2>/dev/null || warn "shadowsocks-libev hindi ma-install."
SS_PASS="$(python3 -c 'import secrets; print(secrets.token_hex(12))')"
if command -v ss-server >/dev/null 2>&1; then
  mkdir -p /etc/shadowsocks-libev
  cat > /etc/shadowsocks-libev/config.json <<SSEOF
{
  "server": "0.0.0.0",
  "server_port": 8388,
  "password": "$SS_PASS",
  "method": "aes-256-gcm",
  "mode": "tcp_and_udp"
}
SSEOF
  printf '%s\n' "$SS_PASS" > /etc/jepongvpn/shadowsocks-pass.txt
  chmod 600 /etc/jepongvpn/shadowsocks-pass.txt
  svc enable shadowsocks-libev; svc restart shadowsocks-libev
  log "Shadowsocks OK (8388)."
else
  warn "Shadowsocks hindi na-install."
fi

# =============================================================================
log "Step 13/18: Hysteria2 (UDP 4443)..."
HY_PASS="$(python3 -c 'import secrets; print(secrets.token_hex(12))')"
if [ ! -x /usr/local/bin/hysteria ]; then
  HY_URL="$(curl -fsSL https://api.github.com/repos/apernet/hysteria/releases/latest 2>/dev/null | grep -o 'https://[^"]*hysteria-linux-amd64' | head -1)"
  if [ -n "$HY_URL" ]; then
    curl -fsSL -o /usr/local/bin/hysteria "$HY_URL" && chmod +x /usr/local/bin/hysteria \
      && log "hysteria binary na-download." \
      || warn "hysteria download pumalya."
  else
    warn "hysteria release URL hindi nahanap."
  fi
fi
if [ -x /usr/local/bin/hysteria ]; then
  mkdir -p /etc/hysteria
  cat > /etc/hysteria/config.yaml <<HYEOF
listen: :4443
tls:
  cert: /etc/letsencrypt/live/$DOMAIN/fullchain.pem
  key: /etc/letsencrypt/live/$DOMAIN/privkey.pem
auth:
  type: password
  password: $HY_PASS
masquerade:
  type: proxy
  proxy:
    url: https://$DOMAIN
    rewriteHost: true
HYEOF
  cat > /etc/systemd/system/hysteria.service <<HYSVEOF
[Unit]
Description=Hysteria2 server
After=network.target
[Service]
Type=simple
ExecStart=/usr/local/bin/hysteria server -c /etc/hysteria/config.yaml
Restart=always
RestartSec=3
[Install]
WantedBy=multi-user.target
HYSVEOF
  if [ "$HAS_SYSTEMD" -eq 1 ]; then systemctl daemon-reload; fi
  printf '%s\n' "$HY_PASS" > /etc/jepongvpn/hysteria-pass.txt
  chmod 600 /etc/jepongvpn/hysteria-pass.txt
  svc enable hysteria; svc restart hysteria
  log "Hysteria2 OK (4443/udp)."
else
  warn "Hysteria2 hindi na-install."
fi

# =============================================================================
log "Step 14/18: OpenVPN TCP (1194/tcp, reuse PKI)..."
OVPN_CONF=""
OVPN_DIR=""
OVPN_SVC=""
if [ -f /etc/openvpn/server/server-tcp.conf ] || [ -f /etc/openvpn/server-tcp.conf ]; then
  log "OpenVPN TCP ay nandiyan na — nilaktawan."
elif [ -f /etc/openvpn/server/server.conf ]; then
  OVPN_CONF="/etc/openvpn/server/server.conf"
  OVPN_DIR="/etc/openvpn/server"
  OVPN_SVC="openvpn-server@server-tcp"
elif [ -f /etc/openvpn/server.conf ]; then
  OVPN_CONF="/etc/openvpn/server.conf"
  OVPN_DIR="/etc/openvpn"
  OVPN_SVC="openvpn@server-tcp"
fi
if [ -n "$OVPN_CONF" ]; then
  sed -e 's/^proto udp.*/proto tcp/' \
      -e 's/^port 1194.*/port 1194/' \
      -e 's|^status .*|status /var/log/openvpn-tcp-status.log|' \
      "$OVPN_CONF" > "$OVPN_DIR/server-tcp.conf"
  sed -i -E 's/^server [0-9.]+ [0-9.]+/server 10.9.0.0 255.255.255.0/' "$OVPN_DIR/server-tcp.conf"
  sed -i '/^explicit-exit-notify/d' "$OVPN_DIR/server-tcp.conf"
  svc enable "$OVPN_SVC"; svc start "$OVPN_SVC"
  log "OpenVPN TCP OK (1194/tcp, config: $OVPN_DIR/server-tcp.conf)."
elif [ ! -f /etc/openvpn/server/server-tcp.conf ] && [ ! -f /etc/openvpn/server-tcp.conf ]; then
  warn "OpenVPN UDP wala pa (walang server.conf) — nilaktawan ang TCP instance."
fi

# =============================================================================
log "Step 15/18: L2TP/IPSec (strongSwan + xl2tpd)..."
apt-get install -y -qq strongswan strongswan-pki xl2tpd 2>/dev/null || warn "strongswan/xl2tpd hindi ma-install."
# trixie/strongSwan 6.0: ang `ipsec` ay nasa HIWALAY na strongswan-starter package (wala sa base strongswan).
# Subukan ito nang hiwalay — harmless kung walang ganyang package (bundled na ang starter sa luma).
apt-get install -y -qq strongswan-starter 2>/dev/null || true
# daemon-reload BAGO ang re-detect (proven 2026-10-25 Ubuntu-2 + Debian): bagong install ang starter unit, hindi pa ito nakikita ng list-unit-files hangga't hindi nagre-reload.
systemctl daemon-reload 2>/dev/null || true
# Re-detect SS_SVC PAGKATAPOS mag-install (ang starter unit ay lumilitaw lang kapag na-install na ang package;
# ang detection sa itaas ay masyadong maaga para sa fresh install kaya nananatili sa "strongswan" at pumapalya ang restart).
if systemctl list-unit-files 2>/dev/null | grep -q "^strongswan-starter.service"; then
  SS_SVC="strongswan-starter"
fi
L2TP_PSK="$(python3 -c 'import secrets; print(secrets.token_hex(12))')"
L2TP_USER="jepong"
L2TP_PASS="$(python3 -c 'import secrets; print(secrets.token_hex(8))')"
if command -v ipsec >/dev/null 2>&1 && command -v xl2tpd >/dev/null 2>&1; then
  cat > /etc/ipsec.conf <<IPEOF
config setup
    charondebug="ike 1, knl 1, cfg 0"
    uniqueids=no
conn l2tp-psk
    auto=add
    authby=secret
    pfs=no
    ike=aes256-sha1-modp1024!
    esp=aes256-sha1!
    type=transport
    left=%defaultroute
    leftprotoport=17/1701
    right=%any
    rightprotoport=17/%any
    dpdaction=clear
    dpddelay=30s
IPEOF
  printf '%%any : PSK "%s"\n' "$L2TP_PSK" > /etc/ipsec.secrets
  chmod 600 /etc/ipsec.secrets
  cat > /etc/xl2tpd/xl2tpd.conf <<XLEOF
[global]
port = 1701
[lns default]
ip range = 10.10.0.10-10.10.0.100
local ip = 10.10.0.1
require chap = yes
refuse pap = yes
require authentication = yes
name = JepongVPN
ppp debug = no
pppoptfile = /etc/ppp/options.xl2tpd
length bit = yes
XLEOF
  cat > /etc/ppp/options.xl2tpd <<PPEOF
ipcp-accept-local
ipcp-accept-remote
ms-dns 1.1.1.1
ms-dns 8.8.8.8
noccp
auth
idle 1800
mtu 1410
mru 1410
nodefaultroute
debug
proxyarp
connect-delay 5000
PPEOF
  printf '%s * %s *\n' "$L2TP_USER" "$L2TP_PASS" > /etc/ppp/chap-secrets
  chmod 600 /etc/ppp/chap-secrets
  grep -q 'net.ipv4.ip_forward=1' /etc/sysctl.conf 2>/dev/null || echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
  sysctl -p >/dev/null 2>&1 || true
  iptables -t nat -C POSTROUTING -s 10.10.0.0/24 -j MASQUERADE 2>/dev/null \
    || iptables -t nat -A POSTROUTING -s 10.10.0.0/24 -j MASQUERADE
  netfilter-persistent save >/dev/null 2>&1 || true
  printf '%s\n%s\n%s\n' "$L2TP_PSK" "$L2TP_USER" "$L2TP_PASS" > /etc/jepongvpn/l2tp-creds.txt
  chmod 600 /etc/jepongvpn/l2tp-creds.txt
  svc enable "$SS_SVC"; svc restart "$SS_SVC"
  svc enable xl2tpd; svc restart xl2tpd
  log "L2TP/IPSec OK (500,4500,1701/udp)."
else
  warn "L2TP/IPSec hindi na-install."
fi

# =============================================================================
log "Step 16/18: IKEv2 (strongSwan EAP)..."
IKE_USER="jepong"
IKE_PASS="$(python3 -c 'import secrets; print(secrets.token_hex(8))')"
if command -v ipsec >/dev/null 2>&1; then
  mkdir -p /etc/ipsec.d/cacerts /etc/ipsec.d/certs /etc/ipsec.d/private
  if [ ! -f /etc/ipsec.d/cacerts/ca-cert.pem ]; then
    if command -v pki >/dev/null 2>&1; then
      pki --gen --type rsa --size 4096 --outform pem > /etc/ipsec.d/private/ca-key.pem
      pki --self --ca --lifetime 3650 --in /etc/ipsec.d/private/ca-key.pem \
        --type rsa --dn "CN=JepongVPN CA" --outform pem > /etc/ipsec.d/cacerts/ca-cert.pem
      pki --gen --type rsa --size 4096 --outform pem > /etc/ipsec.d/private/server-key.pem
      pki --pub --in /etc/ipsec.d/private/server-key.pem --type rsa \
        | pki --issue --lifetime 3650 --cacert /etc/ipsec.d/cacerts/ca-cert.pem \
          --cakey /etc/ipsec.d/private/ca-key.pem --dn "CN=$DOMAIN" \
          --san "$DOMAIN" --flag serverAuth --flag ikeIntermediate \
          --outform pem > /etc/ipsec.d/certs/server-cert.pem
    else
      # openssl fallback (kapag walang pki tool)
      openssl req -x509 -newkey rsa:4096 -keyout /etc/ipsec.d/private/ca-key.pem \
        -out /etc/ipsec.d/cacerts/ca-cert.pem -days 3650 -nodes -subj "/CN=JepongVPN CA" 2>/dev/null
      openssl req -newkey rsa:4096 -keyout /etc/ipsec.d/private/server-key.pem \
        -out /tmp/jepong-server.csr -nodes -subj "/CN=$DOMAIN" 2>/dev/null
      printf "[v3_req]\nsubjectAltName=DNS:%s\nextendedKeyUsage=serverAuth,1.3.6.1.5.5.8.2.2\n" "$DOMAIN" > /tmp/jepong-v3.ext
      openssl x509 -req -in /tmp/jepong-server.csr -CA /etc/ipsec.d/cacerts/ca-cert.pem \
        -CAkey /etc/ipsec.d/private/ca-key.pem -CAcreateserial \
        -out /etc/ipsec.d/certs/server-cert.pem -days 3650 \
        -extensions v3_req -extfile /tmp/jepong-v3.ext 2>/dev/null
      rm -f /tmp/jepong-server.csr /tmp/jepong-v3.ext /etc/ipsec.d/cacerts/ca-cert.srl
    fi
  fi
  cat >> /etc/ipsec.conf <<IKEEOF

conn ikev2-eap
    auto=add
    compress=no
    type=tunnel
    keyexchange=ikev2
    fragmentation=yes
    forceencaps=yes
    dpdaction=clear
    dpddelay=300s
    rekey=no
    left=%any
    leftid=@$DOMAIN
    leftcert=server-cert.pem
    leftsendcert=always
    leftsubnet=0.0.0.0/0
    right=%any
    rightid=%any
    rightauth=eap-mschapv2
    rightsourceip=10.11.0.0/24
    rightdns=1.1.1.1,8.8.8.8
    rightsendcert=never
    eap_identity=%identity
IKEEOF
  printf '%s : EAP "%s"\n' "$IKE_USER" "$IKE_PASS" >> /etc/ipsec.secrets
  printf '%s\n%s\n' "$IKE_USER" "$IKE_PASS" > /etc/jepongvpn/ikev2-creds.txt
  chmod 600 /etc/jepongvpn/ikev2-creds.txt
  iptables -t nat -C POSTROUTING -s 10.11.0.0/24 -j MASQUERADE 2>/dev/null \
    || iptables -t nat -A POSTROUTING -s 10.11.0.0/24 -j MASQUERADE
  netfilter-persistent save >/dev/null 2>&1 || true
  svc restart "$SS_SVC"
  log "IKEv2 OK (500,4500/udp)."
else
  warn "IKEv2 hindi na-install."
fi

# =============================================================================
log "Step 17/18: PPTP (1723/tcp)..."
apt-get install -y -qq pptpd 2>/dev/null || warn "pptpd hindi ma-install."
# PPTP fallback para sa Ubuntu 24.04+ (tinanggal ang pptpd sa apt):
# i-extract ang jammy package nang mano-mano (walang dpkg dependency check).
# Ang binary ay kailangan lang ng libwrap + libc (parehong available sa noble);
# ang ppp/bcrelay constraints ay packaging lang, hindi runtime needs.
if ! command -v pptpd >/dev/null 2>&1; then
  log "pptpd wala sa apt — sinusubukan ang Ubuntu jammy package (manual extract)..."
  apt-get install -y -qq libwrap0 ppp 2>/dev/null || true
  if curl -fsSL -o /tmp/pptpd.deb "http://archive.ubuntu.com/ubuntu/pool/main/p/pptpd/pptpd_1.4.0-12build2_amd64.deb" 2>/dev/null; then
    mkdir -p /tmp/pptpd-x
    if dpkg-deb -x /tmp/pptpd.deb /tmp/pptpd-x 2>/dev/null && [ -f /tmp/pptpd-x/usr/sbin/pptpd ]; then
      cp /tmp/pptpd-x/usr/sbin/pptpd /usr/sbin/pptpd
      chmod +x /usr/sbin/pptpd
      cat > /etc/systemd/system/pptpd.service <<'PPTPSVEOF'
[Unit]
Description=PoPToP Point to Point Tunneling Server
After=network.target
[Service]
EnvironmentFile=-/etc/default/pptpd
ExecStart=/usr/sbin/pptpd --fg $DAEMON_OPTS
[Install]
WantedBy=multi-user.target
PPTPSVEOF
      if [ "$HAS_SYSTEMD" -eq 1 ]; then systemctl daemon-reload; fi
      log "pptpd binary na-install mula sa jammy package."
    else
      warn "pptpd .deb extract pumalya."
    fi
    rm -rf /tmp/pptpd.deb /tmp/pptpd-x
  else
    warn "pptpd .deb download pumalya."
  fi
fi
PPTP_USER="jepong"
PPTP_PASS="$(python3 -c 'import secrets; print(secrets.token_hex(8))')"
if command -v pptpd >/dev/null 2>&1; then
  cat > /etc/pptpd.conf <<PPEOF2
option /etc/ppp/pptpd-options
logwtmp
localip 10.12.0.1
remoteip 10.12.0.10-100
PPEOF2
  cat > /etc/ppp/pptpd-options <<PPOOF
name pptpd
refuse-pap
refuse-chap
refuse-mschap
require-mschap-v2
require-mppe-128
ms-dns 1.1.1.1
ms-dns 8.8.8.8
proxyarp
nodefaultroute
lock
nobsdcomp
novj
novjccomp
nologfd
PPOOF
  printf '%s pptpd %s *\n' "$PPTP_USER" "$PPTP_PASS" >> /etc/ppp/chap-secrets
  printf '%s\n%s\n' "$PPTP_USER" "$PPTP_PASS" > /etc/jepongvpn/pptp-creds.txt
  chmod 600 /etc/jepongvpn/pptp-creds.txt
  iptables -t nat -C POSTROUTING -s 10.12.0.0/24 -j MASQUERADE 2>/dev/null \
    || iptables -t nat -A POSTROUTING -s 10.12.0.0/24 -j MASQUERADE
  netfilter-persistent save >/dev/null 2>&1 || true
  svc enable pptpd; svc restart pptpd
  log "PPTP OK (1723/tcp)."
else
  warn "PPTP hindi na-install (apt at jammy fallback parehong pumalya)."
fi

# =============================================================================
log "Step 18/18: UFW firewall..."
if ! command -v ufw >/dev/null 2>&1; then
  warn "ufw ay wala — sinusubukang i-install."
  apt-get update -qq 2>/dev/null; apt-get install -y -qq ufw 2>/dev/null \
    && log "ufw na-install." \
    || warn "ufw hindi ma-install — walang firewall."
fi
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
  ufw allow 51820/udp >/dev/null
  ufw allow 8388/tcp >/dev/null
  ufw allow 8388/udp >/dev/null
  ufw allow 4443/udp >/dev/null
  ufw allow 1194/tcp >/dev/null
  ufw allow 500/udp >/dev/null
  ufw allow 4500/udp >/dev/null
  ufw allow 1701/udp >/dev/null
  ufw allow 1723/tcp >/dev/null
  if ufw --force enable; then log "UFW active."; else warn "UFW enable pumalya."; fi
else
  warn "UFW hindi gumana dito."
fi
svc enable fail2ban; svc start fail2ban

# vpn-adduser + vpn-menu helpers — kunin mula sa GitHub repo para isang install lang
HELPER_BASE="https://raw.githubusercontent.com/JepongDevxyz/jepong-devxyz-vpn-script-/main"
HELPER_CB="$(date +%s)"
for h in vpn-adduser vpn-menu; do
  if curl -fsSL -o "/usr/local/bin/$h" "$HELPER_BASE/$h.sh?cb=$HELPER_CB"; then
    chmod +x "/usr/local/bin/$h"
    log "$h installed."
  else
    warn "hindi na-download ang $h helper mula sa $HELPER_BASE/$h.sh"
  fi
done

# =============================================================================
echo ""
echo "##############################################################"
echo "#                                                            #"
echo "#   SUCCESSFULLY INSTALLED - JEPONG DEVXYZ SCRIPT             #"
echo "#                                                            #"
echo "##############################################################"
echo "=============================================================="
echo "  VPN SERVER TAPOS. Heto ang detalye:"
echo "=============================================================="
echo "  Domain........: $DOMAIN ($PUBIP)"
echo ""
echo "  [SSH]"
echo "    OpenSSH.....: port 22"
echo "    Dropbear....: port 109, 143"
if [ -f /etc/ssh/sshd_config.d/00-jepongvpn-password.conf ]; then
if [ "${SSH_PASSWORD_IS_DEFAULT:-0}" -eq 1 ]; then
echo "    Password....: ENABLED (default: JepongDevxyz — PALITAN MO AGAD!)"
else
echo "    Password....: ENABLED (custom password)"
fi
else
echo "    Password....: key-only (walang password na na-set)"
fi
echo ""
echo "  [OpenVPN]"
echo "    UDP 1194, client file: /root/jepong.ovpn"
echo "    TCP 1194 (server-tcp.conf, parehong PKI)"
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
echo "  [WireGuard]"
if [ -f /etc/jepongvpn/wireguard-client.conf ]; then
echo "    UDP 51820, client config: /etc/jepongvpn/wireguard-client.conf"
else
echo "    HINDI NA-INSTALL"
fi
echo ""
echo "  [Shadowsocks]"
if [ -f /etc/jepongvpn/shadowsocks-pass.txt ]; then
echo "    Port 8388, method aes-256-gcm, pass: $(cat /etc/jepongvpn/shadowsocks-pass.txt)"
else
echo "    HINDI NA-INSTALL"
fi
echo ""
echo "  [Hysteria2]"
if [ -f /etc/jepongvpn/hysteria-pass.txt ]; then
echo "    UDP 4443, pass: $(cat /etc/jepongvpn/hysteria-pass.txt)"
else
echo "    HINDI NA-INSTALL"
fi
echo ""
echo "  [OpenVPN TCP]"
if [ -f /etc/openvpn/server/server-tcp.conf ] || [ -f /etc/openvpn/server-tcp.conf ]; then
echo "    TCP 1194 (parehong CA/certs ng UDP)"
else
echo "    HINDI NA-INSTALL"
fi
echo ""
echo "  [L2TP/IPSec]"
if [ -f /etc/jepongvpn/l2tp-creds.txt ]; then
echo "    PSK + user/pass nasa /etc/jepongvpn/l2tp-creds.txt (500,4500,1701/udp)"
else
echo "    HINDI NA-INSTALL"
fi
echo ""
echo "  [IKEv2]"
if [ -f /etc/jepongvpn/ikev2-creds.txt ]; then
echo "    EAP user/pass nasa /etc/jepongvpn/ikev2-creds.txt (500,4500/udp)"
else
echo "    HINDI NA-INSTALL"
fi
echo ""
echo "  [PPTP]"
if [ -f /etc/jepongvpn/pptp-creds.txt ]; then
echo "    TCP 1723, user/pass nasa /etc/jepongvpn/pptp-creds.txt"
else
echo "    HINDI NA-INSTALL"
fi
echo ""
echo "  [Xray Extra Transports]"
echo "    VLESS gRPC: $DOMAIN:443 (serviceName grpc)"
echo "    VLESS XHTTP: $DOMAIN:443 (path /xhttp)"
echo ""
echo "  [WebSocket SSH]"
echo "    ws://$DOMAIN:8080  ->  SSH 127.0.0.1:22"
echo "=============================================================="
echo "  Magdagdag ng SSH user:  sudo vpn-adduser <user> <araw>"
echo "  O buksan ang menu:    sudo vpn-menu"
echo "  Tandaan: itago ang mga credentials sa itaas!"
echo "=============================================================="
echo "#   SUCCESSFULLY INSTALLED - JEPONG DEVXYZ SCRIPT             #"
echo "=============================================================="
