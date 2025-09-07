#!/usr/bin/env bash
set -euo pipefail

# ==========================================================
#  Pi4 Network Sentinel - Health Check
#  Vérifie AdGuard Home + Suricata + nftables + DNS
#  Usage: sudo ./health_check_pi_filter.sh
# ==========================================================

# ---------- CONFIG (adapte si besoin) ----------
PI_IFACE="${PI_IFACE:-eth0}"
PI_IP="${PI_STATIC_IP:-192.168.1.231}"
PI_GW="${PI_GATEWAY:-192.168.1.254}"
LAN_CIDR="${LAN_CIDR:-192.168.1.0/24}"

ADGUARD_HOST="${ADGUARD_HOST:-$PI_IP}"
ADGUARD_UI_PORT="${ADGUARD_UI_PORT:-3000}"
ADGUARD_DNS_PORT="${ADGUARD_DNS_PORT:-53}"

# (Optionnel) Si tu veux tester l'API AdGuard :
ADGUARD_USER="${ADGUARD_USER:-admin}"
ADGUARD_PASS="${ADGUARD_PASS:-ChangeMe!42}"
CHECK_ADGUARD_API="${CHECK_ADGUARD_API:-true}"   # true/false

# Upstreams "sécurité" (ping)
UPSTREAMS=("9.9.9.9" "1.1.1.2")

# Domaines de test
OK_DOMAINS=("cloudflare.com" "quad9.net" "google.com")
BLOCK_DOMAINS=(
  "ads.google.com"
  "doubleclick.net"
  "adservice.google.com"
  "adnxs.com"
  "trackersimulator.org"   # peut retourner NXDOMAIN si liste non présente, c'est ok
)

# ---------- helpers couleurs ----------
GREEN="\e[32m"; YELLOW="\e[33m"; RED="\e[31m"; BLUE="\e[34m"; BOLD="\e[1m"; RESET="\e[0m"
ok()    { echo -e "${GREEN}✔${RESET} $*"; }
warn()  { echo -e "${YELLOW}▲${RESET} $*"; }
err()   { echo -e "${RED}✘${RESET} $*"; }
info()  { echo -e "${BLUE}ℹ${RESET} $*"; }
title() { echo -e "\n${BOLD}$*${RESET}"; }

# ---------- util dispo ----------
have() { command -v "$1" >/dev/null 2>&1; }

# DNS query using dig/nslookup/getent, returns "IP|STATUS"
dns_query() {
  local domain="$1" server="$2"
  if have dig; then
    # +short pour IP, +cmd pour status
    local status ip
    status=$(dig @"$server" "$domain" +time=2 +tries=1 +noidnout +noshort | awk '/status:/{print $6}' | tr -d ',')
    ip=$(dig @"$server" "$domain" +short +time=2 +tries=1 | head -n1)
    echo "${ip}|${status}"
  elif have nslookup; then
    # nslookup retourne l'IP sur la dernière ligne "Address: X.X.X.X"
    local out ip status="UNKNOWN"
    out=$(nslookup "$domain" "$server" 2>/dev/null || true)
    ip=$(echo "$out" | awk '/^Address: /{print $2}' | tail -n1)
    # pas trivial d’avoir le status -> on infère
    if [[ -z "$ip" ]]; then status="NXDOMAIN"; else status="NOERROR"; fi
    echo "${ip}|${status}"
  else
    # fallback minimal
    local ip
    ip=$(getent hosts "$domain" | awk '{print $1}' | head -n1)
    if [[ -z "$ip" ]]; then
      echo "|NXDOMAIN"
    else
      echo "${ip}|NOERROR"
    fi
  fi
}

# ---------- checks ----------
title "1) Réseau & Interface"
ip -br a || true
DEF_ROUTE=$(ip route show default || true)
if echo "$DEF_ROUTE" | grep -q "$PI_GW"; then
  ok "Passerelle par défaut OK → $PI_GW"
else
  warn "Passerelle inattendue. Route par défaut: $DEF_ROUTE"
fi

if ip -br a show "$PI_IFACE" | grep -q "$PI_IP"; then
  ok "Interface ${PI_IFACE} a bien l'IP ${PI_IP}"
else
  err "Interface ${PI_IFACE} n'a pas ${PI_IP}. Vérifie /etc/dhcpcd.conf"
fi

for u in "${UPSTREAMS[@]}"; do
  if ping -c1 -W1 "$u" >/dev/null 2>&1; then
    ok "Upstream $u joignable"
  else
    warn "Upstream $u injoignable (peut être filtré par ICMP, pas bloquant)"
  fi
done

title "2) Services système"
for svc in AdGuardHome suricata nftables; do
  if systemctl is-active --quiet "$svc"; then
    ok "Service $svc actif"
  else
    err "Service $svc inactif"
  fi
done

title "3) Ports à l'écoute"
if have ss; then
  ss -ltnup | awk 'NR==1 || /:53 |:3000 /{print}'
else
  netstat -ltnp 2>/dev/null | awk 'NR==1 || /:53 |:3000 /{print}'
fi

title "4) Tests DNS via AdGuard (${PI_IP}:${ADGUARD_DNS_PORT})"
SERVER="$PI_IP"

for d in "${OK_DOMAINS[@]}"; do
  res=$(dns_query "$d" "$SERVER")
  ipr="${res%%|*}"; st="${res##*|}"
  if [[ "$st" == "NOERROR" && -n "$ipr" ]]; then
    ok "Resolve OK: ${d} -> ${ipr} (status ${st})"
  else
    err "Resolve KO: ${d} (status ${st}, ip '${ipr}')"
  fi
done

BLOCKED=0; TOTAL=0
for d in "${BLOCK_DOMAINS[@]}"; do
  TOTAL=$((TOTAL+1))
  res=$(dns_query "$d" "$SERVER")
  ipr="${res%%|*}"; st="${res##*|}"
  # Cas considérés comme BLOQUÉS: NXDOMAIN / SERVFAIL / REFUSED / réponse 0.0.0.0 / :: / 0.0.0.0-like
  if [[ "$st" != "NOERROR" ]] || [[ "$ipr" == "0.0.0.0" ]] || [[ "$ipr" == "::" ]] || [[ -z "$ipr" ]]; then
    ok "Blocage OK: ${d} (status ${st}, ip '${ipr}')"
    BLOCKED=$((BLOCKED+1))
  else
    warn "Non bloqué (à vérifier): ${d} -> ${ipr} (status ${st})"
  fi
done
echo -e "   → ${BOLD}${BLOCKED}/${TOTAL}${RESET} domaines pubs/trackers semblent BLOQUÉS."

title "5) AdGuard API (optionnel)"
if [[ "$CHECK_ADGUARD_API" == "true" ]]; then
  if have curl; then
    # Essai basique /control/status (Basic Auth)
    URL="http://${ADGUARD_HOST}:${ADGUARD_UI_PORT}/control/status"
    HTTP_CODE=$(curl -s -u "${ADGUARD_USER}:${ADGUARD_PASS}" -o /tmp/agh_status.json -w "%{http_code}" "$URL" || true)
    if [[ "$HTTP_CODE" == "200" ]]; then
      ok "API AdGuard OK (status 200). Extrait :"
      jq -r '.dns_status // .status // .version' /tmp/agh_status.json 2>/dev/null || cat /tmp/agh_status.json
    else
      warn "Impossible de lire l'API AdGuard (HTTP ${HTTP_CODE}). Vérifie user/pass ou l’accès API."
    fi
    rm -f /tmp/agh_status.json
  else
    warn "curl manquant → skip API AdGuard"
  fi
else
  info "CHECK_ADGUARD_API=false → test API sauté"
fi

title "6) Suricata - dernières alertes"
FAST="/var/log/suricata/fast.log"
EVE="/var/log/suricata/eve.json"
if [[ -s "$FAST" ]]; then
  ok "fast.log présent → dernières 10 alertes :"
  tail -n 10 "$FAST" | sed 's/^/   /'
else
  warn "Pas d'alertes dans fast.log (ou fichier absent)."
fi

if [[ -s "$EVE" ]]; then
  if have jq; then
    CNT=$(jq -r 'select(.event_type=="alert") | . | length' "$EVE" 2>/dev/null | wc -l | tr -d ' ')
    info "eve.json présent. (compte brut des lignes alert) ≈ $CNT"
  else
    info "eve.json présent (installe jq pour stats: apt install -y jq)"
  fi
fi

title "7) nftables - règles chargées"
if nft list ruleset >/dev/null 2>&1; then
  ok "nftables ruleset chargé."
  nft list ruleset | sed -e '1,4d' | head -n 30 | sed 's/^/   /'
else
  warn "nftables non chargé."
fi

title "Résumé"
echo -e " • Interface: ${PI_IFACE} / IP: ${PI_IP} / GW: ${PI_GW}"
echo -e " • AdGuard DNS: ${PI_IP}:${ADGUARD_DNS_PORT} / UI: http://${PI_IP}:${ADGUARD_UI_PORT}"
echo -e " • Suricata: logs in /var/log/suricata/"
echo -e " • Blocage pubs/trackers: ${BOLD}${BLOCKED}/${TOTAL}${RESET} (plus c'est élevé, mieux c'est)"
echo
ok "Health-check terminé."