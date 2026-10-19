#!/usr/bin/env bash
#
# vpn-menu.sh — interactive management menu para sa Jepong VPN server
#
# Usage: sudo vpn-menu
#   Auto-installed sa /usr/local/bin/vpn-menu ng vpn-server.sh
#
set -uo pipefail

die() { echo -e "\033[1;31m[x]\033[0m $*" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || die "Patakbuhin as root: sudo vpn-menu"

DB="/etc/jepongvpn/users.db"
DOMAIN="$(cat /etc/jepongvpn/domain.txt 2>/dev/null || echo "")"
NSDOMAIN="$(cat /etc/jepongvpn/nsdomain.txt 2>/dev/null || echo "")"

# --- user listing (mula sa DB, fallback: scan ng may expiry) ---
list_vpn_users() {
  if [ -f "$DB" ]; then
    grep -v '^\s*$' "$DB" 2>/dev/null
  else
    # fallback: mga user na may account expiry (hindi system users)
    while IFS=: read -r u _ uid _ _ _ shell; do
      [ "$uid" -ge 1000 ] 2>/dev/null || continue
      [ "$u" = "ubuntu" ] && continue
      [ "$u" = "nobody" ] && continue
      exp="$(chage -l "$u" 2>/dev/null | grep -i "account expires" | cut -d: -f2 | xargs)"
      [ -n "$exp" ] && [ "$exp" != "never" ] && echo "$u"
    done < /etc/passwd
  fi
}

user_expiry() {
  chage -l "$1" 2>/dev/null | grep -i "account expires" | cut -d: -f2 | xargs
}

menu_adduser() {
  echo ""
  read -rp "  Username (0 = bumalik): " u
  [ "$u" = "0" ] || [ -z "$u" ] && { echo "  bumalik sa menu."; return; }
  read -rp "  Ilang araw (default 30): " d
  d="${d:-30}"
  read -rsp "  Password (blank = random): " p; echo ""
  /usr/local/bin/vpn-adduser "$u" "$d" "$p"
}

menu_deluser() {
  echo ""
  echo "  --- Users ---"
  users="$(list_vpn_users)"
  [ -z "$users" ] && { echo "  walang VPN users."; return; }
  echo "$users" | nl -ba | sed 's/^/  /'
  echo ""
  read -rp "  Username na buburahin (0 = bumalik): " u
  [ "$u" = "0" ] || [ -z "$u" ] && { echo "  bumalik sa menu."; return; }
  id "$u" >/dev/null 2>&1 || { echo "  walang user na $u."; return; }
  read -rp "  Sigurado ka bang burahin si $u? (y/N): " c
  case "$c" in
    y|Y)
      pkill -u "$u" 2>/dev/null || true
      userdel -r "$u" 2>/dev/null || userdel "$u"
      [ -f "$DB" ] && sed -i "/^${u}$/d" "$DB"
      echo "  OK: binura si $u."
      ;;
    *) echo "  kinansela." ;;
  esac
}

menu_listusers() {
  echo ""
  echo "  --- VPN Users ---"
  users="$(list_vpn_users)"
  [ -z "$users" ] && { echo "  walang VPN users."; return; }
  printf "  %-20s %-12s %s\n" "USERNAME" "EXPIRES" "STATUS"
  while read -r u; do
    [ -z "$u" ] && continue
    exp="$(user_expiry "$u")"
    [ -z "$exp" ] && exp="?"
    status="aktibo"
    if [ "$exp" != "never" ] && [ "$exp" != "?" ]; then
      exp_epoch="$(date -d "$exp" +%s 2>/dev/null || echo 0)"
      now_epoch="$(date +%s)"
      [ "$exp_epoch" -lt "$now_epoch" ] && status="EXPIRED"
    fi
    id "$u" >/dev/null 2>&1 || status="binura na?"
    printf "  %-20s %-12s %s\n" "$u" "$exp" "$status"
  done <<< "$users"
}

menu_details() {
  echo ""
  echo "  ================= VPN DETAILS ================="
  echo "  Domain......: ${DOMAIN:-?}"
  [ -f /etc/jepongvpn/xray-creds.txt ] && {
    UUID_VLESS="$(sed -n '1p' /etc/jepongvpn/xray-creds.txt)"
    UUID_VMESS="$(sed -n '2p' /etc/jepongvpn/xray-creds.txt)"
    TROJAN_PASS="$(sed -n '3p' /etc/jepongvpn/xray-creds.txt)"
    echo ""
    echo "  [Xray — port 443]"
    echo "  VLESS link : vless://$UUID_VLESS@$DOMAIN:443?path=%2Fvless&security=tls&encryption=none&type=ws#$DOMAIN-vless"
    echo "  Trojan link: trojan://$TROJAN_PASS@$DOMAIN:443?path=%2Ftrojan&security=tls&type=ws#$DOMAIN-trojan"
  }
  [ -f /etc/jepongvpn/udp-psk.txt ] && {
    echo ""
    echo "  [UDP Custom — port 36712]"
    echo "  PSK: $(cat /etc/jepongvpn/udp-psk.txt)"
  }
  [ -f /etc/dnstt/server.pub ] && {
    echo ""
    echo "  [SlowDNS — ${NSDOMAIN:-?} UDP 53]"
    echo "  Pubkey: $(cat /etc/dnstt/server.pub)"
  }
  [ -f /root/jepong.ovpn ] && {
    echo ""
    echo "  [OpenVPN — UDP 1194]"
    echo "  Client file: /root/jepong.ovpn"
  }
  echo ""
  echo "  [Ports]"
  echo "  SSH 22 | Dropbear 109,143 | WS 8080 | OpenVPN 1194/udp"
  echo "  SlowDNS 53/udp | UDP 36712 + 25000-26000/udp | Xray 443"
  echo "  ================================================="
}

menu_status() {
  echo ""
  echo "  --- Service status ---"
  for s in ssh dropbear xray nginx ssh-ws dnstt udp_custom fail2ban; do
    st="$(systemctl is-active "$s" 2>/dev/null || echo "unknown")"
    printf "  %-12s %s\n" "$s" "$st"
  done
}

menu_restart() {
  echo ""
  for s in ssh dropbear xray nginx ssh-ws dnstt udp_custom fail2ban; do
    if systemctl restart "$s" 2>/dev/null; then
      echo "  [OK] $s restarted"
    else
      echo "  [--] $s wala/hindi na-restart"
    fi
  done
}

menu_reboot() {
  echo ""
  echo "  BABALA: magre-reboot ang VPS — mawawala ang SSH connection mo."
  echo "  Lahat ng services ay automatic na babalik pagka-boot."
  read -rp "  Siguradong i-reboot? (y/N): " c
  case "$c" in
    y|Y)
      echo "  Nire-reboot ang VPS ngayon..."
      sleep 2
      reboot
      ;;
    *) echo "  kinansela." ;;
  esac
}

# ================= MENU LOOP ================
while true; do
  echo ""
  echo "  ======================================="
  echo "      JEPONG DEVXYZ VPS SCRIPT"
  echo "  ======================================="
  echo "   1) Create Account"
  echo "   2) Check Account"
  echo "   3) Delete Account"
  echo "   4) VPN Details"
  echo "   5) Service Status"
  echo "   6) Restart Services"
  echo "   7) Reboot VPS"
  echo "   0) Exit"
  echo "  ======================================="
  read -rp "  Select (0-7): " c
  case "$c" in
    1) menu_adduser ;;
    2) menu_listusers ;;
    3) menu_deluser ;;
    4) menu_details ;;
    5) menu_status ;;
    6) menu_restart ;;
    7) menu_reboot ;;
    0) echo "  Bye!"; exit 0 ;;
    *) echo "  invalid option." ;;
  esac
  echo ""
  read -rp "  Press Enter to return to menu..." _
done
