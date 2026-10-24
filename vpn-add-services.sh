#!/usr/bin/env bash
#
# vpn-add-services.sh — add-on para sa EXISTING JepongDevxyz VPN install
# (JepongDevxyz)
#
# Idadagdag LANG ang mga bagong services (WireGuard, Shadowsocks, Hysteria2,
# Xray gRPC/XHTTP, OpenVPN TCP, L2TP/IPSec, IKEv2, PPTP) nang HINDI ginagalaw
# ang existing services at credentials (Xray UUIDs, Trojan pass, UDP PSK,
# OpenVPN certs, domain, SlowDNS keys).
#
# Run as root sa VPS na may existing install:
#   sudo bash vpn-add-services.sh
#
# Idempotent: ligtas ulitin — ang naka-install na ay nilalaktawan.
#
set -euo pipefail

log()  { echo -e "\033[1;32m[+]\033[0m $*"; }
warn() { echo -e "\033[1;33m[!]\033[0m $*" >&2; }
die()  { echo -e "\033[1;31m[x]\033[0m $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "Patakbuhin as root: sudo bash vpn-add-services.sh"
[ -f /etc/jepongvpn/domain.txt ] || die "Walang existing install — /etc/jepongvpn/domain.txt hindi nahanap. Patakbuhin muna ang vpn-server installer."
DOMAIN="$(cat /etc/jepongvpn/domain.txt)"
export DEBIAN_FRONTEND=noninteractive
log "Domain: $DOMAIN — idadagdag ang mga bagong services (existing install, walang gagalawin)."

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
log "WireGuard (UDP 51820)..."
apt-get install -y -qq wireguard 2>/dev/null || warn "wireguard package hindi ma-install."
if command -v wg >/dev/null 2>&1; then
  if [ -f /etc/wireguard/wg0.conf ]; then
    log "WireGuard ay nandiyan na — nilaktawan."
  else
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
  fi
else
  warn "WireGuard hindi na-install (walang wg binary)."
fi

# =============================================================================
log "Shadowsocks (8388)..."
apt-get install -y -qq shadowsocks-libev 2>/dev/null || warn "shadowsocks-libev hindi ma-install."
if command -v ss-server >/dev/null 2>&1; then
  if [ -f /etc/jepongvpn/shadowsocks-pass.txt ]; then
    log "Shadowsocks ay nandiyan na — nilaktawan."
  else
    SS_PASS="$(python3 -c 'import secrets; print(secrets.token_hex(12))')"
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
  fi
else
  warn "Shadowsocks hindi na-install."
fi

# =============================================================================
log "Hysteria2 (UDP 4443)..."
if [ -f /etc/jepongvpn/hysteria-pass.txt ]; then
  log "Hysteria2 ay nandiyan na — nilaktawan."
else
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
fi

# =============================================================================
log "Xray gRPC + XHTTP (idinagdag sa EXISTING config, hindi inulit)..."
if [ -f /usr/local/etc/xray/config.json ] && command -v python3 >/dev/null 2>&1; then
  python3 - <<'PYEOF'
import json
path = '/usr/local/etc/xray/config.json'
with open(path) as f:
    config = json.load(f)
nets = [i.get('streamSettings', {}).get('network') for i in config['inbounds']]
if 'grpc' in nets and 'xhttp' in nets:
    print("Xray grpc/xhttp ay nandiyan na — nilaktawan.")
else:
    vless_id = None
    for i in config['inbounds']:
        if i['protocol'] == 'vless':
            vless_id = i['settings']['clients'][0]['id']
            break
    if vless_id is None:
        print("Walang VLESS inbound — nilaktawan ang grpc/xhttp.")
    else:
        if 'grpc' not in nets:
            config['inbounds'].append({
                "port": 10004, "listen": "127.0.0.1", "protocol": "vless",
                "settings": {"clients": [{"id": vless_id}], "decryption": "none"},
                "streamSettings": {"network": "grpc", "grpcSettings": {"serviceName": "grpc"}},
            })
        if 'xhttp' not in nets:
            config['inbounds'].append({
                "port": 10005, "listen": "127.0.0.1", "protocol": "vless",
                "settings": {"clients": [{"id": vless_id}], "decryption": "none"},
                "streamSettings": {"network": "xhttp", "xhttpSettings": {"path": "/xhttp"}},
            })
        with open(path, 'w') as f:
            json.dump(config, f, indent=2)
        print("Xray grpc/xhttp inbounds nadagdag.")
PYEOF
  if command -v xray >/dev/null 2>&1 && xray run -test -c /usr/local/etc/xray/config.json >/dev/null 2>&1; then
    log "xray config valid pagkatapos ng dagdag."
    svc restart xray
  else
    warn "xray config test pumalya — i-check ang /usr/local/etc/xray/config.json."
  fi
  # nginx: idagdag ang grpc + xhttp locations (kung wala pa)
  if [ -f /etc/nginx/sites-available/vpn ] && ! grep -q 'grpc_pass' /etc/nginx/sites-available/vpn; then
    python3 - <<'PYEOF'
path = '/etc/nginx/sites-available/vpn'
with open(path) as f:
    content = f.read()
marker = '    location = /trojan {'
idx = content.index(marker)
end = content.index('\n    }\n', idx) + len('\n    }\n')
insert = '''    location /grpc {
        grpc_pass grpc://127.0.0.1:10004;
    }
    location = /xhttp {
        proxy_pass http://127.0.0.1:10005;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
    }
'''
content = content[:end] + insert + content[end:]
with open(path, 'w') as f:
    f.write(content)
print("nginx grpc/xhttp locations nadagdag.")
PYEOF
    if nginx -t 2>/dev/null; then
      svc reload nginx 2>/dev/null || svc restart nginx
      log "nginx reloaded."
    else
      warn "nginx -t pumalya — i-check ang /etc/nginx/sites-available/vpn."
    fi
  else
    log "nginx grpc/xhttp ay nandiyan na o walang vhost — nilaktawan."
  fi
else
  warn "Walang Xray config — nilaktawan ang grpc/xhttp."
fi

# =============================================================================
log "OpenVPN TCP (1194/tcp, reuse PKI)..."
# Kung walang OpenVPN UDP config (posibleng hindi na-install noong una),
# subukan munang i-install ang UDP via angristan bago gumawa ng TCP instance
if [ ! -f /etc/openvpn/server/server.conf ] && [ ! -f /etc/openvpn/server.conf ]; then
  log "Walang OpenVPN UDP config — sinusubukang i-install via angristan..."
  curl -fsSL -o /root/openvpn-install.sh \
    https://raw.githubusercontent.com/angristan/openvpn-install/master/openvpn-install.sh
  chmod +x /root/openvpn-install.sh
  AUTO_INSTALL=y APPROVE_INSTALL=y APPROVE_IP=y IPV6_SUPPORT=n \
    PORT_CHOICE=1 PROTOCOL_CHOICE=1 DNS=1 COMPRESSION_ENABLED=n CUSTOMIZE_ENC=n \
    CLIENT=jepong PASS=1 ENDPOINT="$DOMAIN" bash /root/openvpn-install.sh \
    || warn "angristan OpenVPN install pumalya — tingnan ang output sa itaas."
  # Verification: siguruhing may nalikha talagang config (hindi silent fail tulad noong una)
  if [ ! -f /etc/openvpn/server/server.conf ] && [ ! -f /etc/openvpn/server.conf ]; then
    warn "angristan tumakbo pero WALANG server.conf na nalikha — susubukan ang MANUAL setup."
  else
    log "OpenVPN UDP config nalikha — itutuloy ang TCP instance."
  fi
fi
# MANUAL FALLBACK: kung wala pa ring config pagkatapos ng angristan, gumawa ng
# OpenVPN setup nang mano-mano (apt + easy-rsa, walang angristan).
if [ ! -f /etc/openvpn/server/server.conf ] && [ ! -f /etc/openvpn/server.conf ]; then
  log "Manual OpenVPN setup (apt + easy-rsa)..."
  apt-get install -y -qq openvpn easy-rsa 2>/dev/null || warn "openvpn/easy-rsa hindi ma-install."
  if command -v openvpn >/dev/null 2>&1; then
    mkdir -p /etc/openvpn/server /etc/openvpn/easy-rsa
    if [ ! -f /etc/openvpn/server/ca.crt ]; then
      if [ -d /usr/share/easy-rsa ]; then
        cp -r /usr/share/easy-rsa/* /etc/openvpn/easy-rsa/ 2>/dev/null || true
      fi
      if [ ! -f /etc/openvpn/easy-rsa/easyrsa ]; then
        warn "easy-rsa templates hindi nahanap sa /usr/share/easy-rsa — sinusubukang i-download."
        EASYRSA_TGZ="$(curl -fsSL https://api.github.com/repos/OpenVPN/easy-rsa/releases/latest 2>/dev/null | grep -o 'https://[^"]*EasyRSA-3[^"]*\.tgz' | head -1)"
        if [ -n "$EASYRSA_TGZ" ]; then
          curl -fsSL -o /tmp/easyrsa.tgz "$EASYRSA_TGZ" && tar -xzf /tmp/easyrsa.tgz -C /tmp             && cp -r /tmp/EasyRSA-*/easyrsa3/* /etc/openvpn/easy-rsa/ 2>/dev/null             && log "easy-rsa na-download." || warn "easy-rsa download pumalya."
        fi
      fi
      if [ -f /etc/openvpn/easy-rsa/easyrsa ]; then
        cd /etc/openvpn/easy-rsa
        ./easyrsa init-pki >/dev/null 2>&1
        ./easyrsa --batch build-ca nopass >/dev/null 2>&1
        ./easyrsa --batch build-server-full server nopass >/dev/null 2>&1
        ./easyrsa --batch build-client-full jepong nopass >/dev/null 2>&1
        ./easyrsa --batch gen-dh >/dev/null 2>&1
        openvpn --genkey secret /etc/openvpn/server/ta.key 2>/dev/null
        cp pki/ca.crt pki/issued/server.crt pki/private/server.key pki/dh.pem /etc/openvpn/server/ 2>/dev/null
        cd /
        log "OpenVPN PKI nalikha."
      else
        warn "easyrsa binary hindi nahanap — hindi matutuloy ang manual setup."
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
      # Client file
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
      iptables -t nat -C POSTROUTING -s 10.8.0.0/24 -j MASQUERADE 2>/dev/null         || iptables -t nat -A POSTROUTING -s 10.8.0.0/24 -j MASQUERADE
      iptables -t nat -C POSTROUTING -s 10.9.0.0/24 -j MASQUERADE 2>/dev/null         || iptables -t nat -A POSTROUTING -s 10.9.0.0/24 -j MASQUERADE
      netfilter-persistent save >/dev/null 2>&1 || true
      svc enable openvpn-server@server; svc start openvpn-server@server
      log "Manual OpenVPN UDP OK (1194/udp, client: /root/jepong.ovpn)."
    else
      warn "Manual OpenVPN setup pumalya (walang ca.crt)."
    fi
  else
    warn "openvpn binary wala pa rin pagkatapos ng apt install."
  fi
fi
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
log "L2TP/IPSec (strongSwan + xl2tpd)..."
apt-get install -y -qq strongswan strongswan-pki xl2tpd 2>/dev/null || warn "strongswan/xl2tpd hindi ma-install."
if command -v ipsec >/dev/null 2>&1 && command -v xl2tpd >/dev/null 2>&1; then
  if [ -f /etc/jepongvpn/l2tp-creds.txt ]; then
    log "L2TP/IPSec ay nandiyan na — nilaktawan."
  else
    L2TP_PSK="$(python3 -c 'import secrets; print(secrets.token_hex(12))')"
    L2TP_USER="jepong"
    L2TP_PASS="$(python3 -c 'import secrets; print(secrets.token_hex(8))')"
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
  fi
else
  warn "L2TP/IPSec hindi na-install."
fi

# =============================================================================
log "IKEv2 (strongSwan EAP)..."
if [ -f /etc/jepongvpn/ikev2-creds.txt ]; then
  log "IKEv2 ay nandiyan na — nilaktawan."
elif command -v ipsec >/dev/null 2>&1; then
  IKE_USER="jepong"
  IKE_PASS="$(python3 -c 'import secrets; print(secrets.token_hex(8))')"
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
log "PPTP (1723/tcp)..."
apt-get install -y -qq pptpd 2>/dev/null || warn "pptpd hindi ma-install."
if command -v pptpd >/dev/null 2>&1; then
  if [ -f /etc/jepongvpn/pptp-creds.txt ]; then
    log "PPTP ay nandiyan na — nilaktawan."
  else
    PPTP_USER="jepong"
    PPTP_PASS="$(python3 -c 'import secrets; print(secrets.token_hex(8))')"
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
  fi
else
  warn "PPTP hindi na-install (Ubuntu 24.04: tinanggal ng Ubuntu ang pptpd package — hindi available via apt; sa Debian gumagana pa)."
fi

# =============================================================================
log "UFW: idagdag ang bagong ports (HINDI reset — existing rules mananatili)..."
if command -v ufw >/dev/null 2>&1; then
  ufw allow 51820/udp >/dev/null 2>&1
  ufw allow 8388/tcp >/dev/null 2>&1
  ufw allow 8388/udp >/dev/null 2>&1
  ufw allow 4443/udp >/dev/null 2>&1
  ufw allow 1194/tcp >/dev/null 2>&1
  ufw allow 500/udp >/dev/null 2>&1
  ufw allow 4500/udp >/dev/null 2>&1
  ufw allow 1701/udp >/dev/null 2>&1
  ufw allow 1723/tcp >/dev/null 2>&1
  log "UFW bagong ports nadagdag."
else
  warn "ufw wala — nilaktawan ang firewall rules."
fi

# Menu: i-update para makita ang bagong services sa VPN Details
HELPER_BASE="https://raw.githubusercontent.com/JepongDevxyz/jepong-devxyz-vpn-script-/main"
if curl -fsSL -o /usr/local/bin/vpn-menu "$HELPER_BASE/vpn-menu.sh?cb=$(date +%s)"; then
  chmod +x /usr/local/bin/vpn-menu
  log "vpn-menu updated."
else
  warn "hindi na-update ang vpn-menu."
fi

# =============================================================================
echo ""
echo "##############################################################"
echo "#                                                            #"
echo "#   BAGONG SERVICES NAIDAGDAG - JEPONG DEVXYZ SCRIPT          #"
echo "#                                                            #"
echo "##############################################################"
echo "  Domain........: $DOMAIN"
echo "  (Existing services at credentials: HINDI ginalaw)"
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
echo "  [Xray Extra Transports]"
echo "    VLESS gRPC: $DOMAIN:443 (serviceName grpc)"
echo "    VLESS XHTTP: $DOMAIN:443 (path /xhttp)"
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
echo "=============================================================="
echo "  Tingnan ang detalye:  sudo vpn-menu  ->  4 (VPN Details)"
echo "=============================================================="
