#!/usr/bin/env bash
#
# vpn-adduser.sh — magdagdag ng SSH user na may expiry (para sa VPN server)
#
# Usage: sudo bash vpn-adduser.sh <username> [araw] [password]
#   <username>  bagong username
#   [araw]      ilang araw bago mag-expire (default: 30)
#   [password]  password (default: random)
#
# Halimbawa: sudo bash vpn-adduser.sh jepong1 30
#
set -euo pipefail

die() { echo -e "\033[1;31m[x]\033[0m $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "Patakbuhin as root: sudo bash vpn-adduser.sh <username> [araw]"
USER="${1:-}"; DAYS="${2:-30}"; PASS="${3:-}"
[ -n "$USER" ] || die "Usage: sudo bash vpn-adduser.sh <username> [araw] [password]"
id "$USER" >/dev/null 2>&1 && die "may user nang $USER"

[ -z "$PASS" ] && PASS="$(python3 -c 'import secrets,string; print("".join(secrets.choice(string.ascii_letters+string.digits) for _ in range(10)))')"
EXPIRY="$(date -d "+$DAYS days" +%Y-%m-%d)"

useradd -m -s /bin/false -e "$EXPIRY" "$USER"
echo "$USER:$PASS" | chpasswd

echo "OK: user $USER nilikha."
echo "  Username : $USER"
echo "  Password : $PASS"
echo "  Expire   : $EXPIRY ($DAYS araw)"
