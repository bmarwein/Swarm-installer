#!/usr/bin/env bash
set -euo pipefail

# === Paramètres (adapte au besoin) ===
STATIC_IP="192.168.1.231"
LAN_CIDR="192.168.1.0/24"
IFACE="eth0"
ADGUARD_UI_PORT="3000"
ADGUARD_ADMIN_USER="admin"
ADGUARD_ADMIN_PASS="ChangeMe!42"
UPSTREAM_DNS=("9.9.9.9" "1.1.1.2")
BOOTSTRAP_DNS=("9.9.9.10" "1.1.1.1")
ADGUARD_FILTERS=(
  "https://adguardteam.github.io/AdGuardSDNSFilter/Filters/filter.txt|AdGuard DNS filter"
  "https://oisd.nl/basic.txt|OISD Basic"
  "https://malware-filter.gitlab.io/malware-filter/urlhaus-filter-online.txt|URLHaus Malware"
)

echo "[A] Config AdGuard Home (post-install)…"
sudo systemctl stop AdGuardHome

# Hash bcrypt pour le compte admin
if ! command -v htpasswd >/dev/null 2>&1; then
  sudo apt-get update -y && sudo apt-get install -y apache2-utils
fi
BCRYPT_HASH="$(htpasswd -nBC 10 "" "${ADGUARD_ADMIN_PASS}" 2>/dev/null | tr -d ':\n')"
BCRYPT_HASH="${BCRYPT_HASH/\$2y\$/\$2a\$}"

# Construit upstreams / bootstraps / filters
UPS=""; for u in "${UPSTREAM_DNS[@]}";   do UPS+="    - ${u}\n"; done
BOOT=""; for b in "${BOOTSTRAP_DNS[@]}"; do BOOT+="    - ${b}\n"; done
FILS=""; fid=1
for line in "${ADGUARD_FILTERS[@]}"; do
  url="${line%%|*}"; name="${line#*|}"
  FILS+="  - enabled: true\n    url: ${url}\n    name: ${name}\n    id: ${fid}\n"
  fid=$((fid+1))
done

sudo mkdir -p /opt/AdGuardHome
# Sauvegarde éventuelle
if [ -f /opt/AdGuardHome/AdGuardHome.yaml ]; then
  sudo cp -a /opt/AdGuardHome/AdGuardHome.yaml /opt/AdGuardHome/AdGuardHome.yaml.bak.$(date +%F-%H%M%S)
fi

# YAML minimal prêt-à-l’emploi
cat <<EOF | sudo tee /opt/AdGuardHome/AdGuardHome.yaml >/dev/null
bind_host: 0.0.0.0
bind_port: ${ADGUARD_UI_PORT}
users:
  - name: ${ADGUARD_ADMIN_USER}
    password: ${BCRYPT_HASH}
http:
  address: 0.0.0.0:${ADGUARD_UI_PORT}
dns:
  bind_hosts:
    - 0.0.0.0
  port: 53
  upstreams:
$(printf "${UPS}")
  bootstrap_dns:
$(printf "${BOOT}")
  protection_enabled: true
  blocking_mode: default
  ratelimit: 20
  cache_size: 128
  filters_update_interval: 24
filters:
$(printf "${FILS}")
EOF

sudo systemctl daemon-reload
sudo systemctl enable AdGuardHome
sudo systemctl start AdGuardHome
sleep 2
sudo systemctl --no-pager --full status AdGuardHome || true
echo "→ AdGuard prêt: http://${STATIC_IP}:${ADGUARD_UI_PORT} (admin / ${ADGUARD_ADMIN_PASS})"

echo "[B] Installation Suricata (IDS)…"
if ! dpkg -s suricata >/dev/null 2>&1; then
  sudo apt-get install -y suricata
fi
sudo cp -a /etc/suricata/suricata.yaml /etc/suricata/suricata.yaml.bak.$(date +%F-%H%M%S)
sudo sed -i "s|^\(\s*HOME_NET:\s*\).*|\1\"[${LAN_CIDR}]\"|g" /etc/suricata/suricata.yaml
if ! grep -q "af-packet:" /etc/suricata/suricata.yaml; then
  cat <<'EOPK' | sudo tee -a /etc/suricata/suricata.yaml >/dev/null

af-packet:
  - interface: eth0
    cluster-id: 99
    cluster-type: cluster_flow
    defrag: yes
EOPK
fi
sudo sed -i "s/interface:\s*.*/interface: ${IFACE}/" /etc/suricata/suricata.yaml
sudo suricata-update || true
sudo systemctl enable suricata
sudo systemctl restart suricata
sleep 2
sudo systemctl --no-pager --full status suricata || true
echo "→ Suricata (IDS) actif. Logs: /var/log/suricata/"

echo "[C] Pare-feu nftables minimal (LAN uniquement)…"
sudo bash -c 'cat >/etc/nftables.conf' <<'NFT'
#!/usr/sbin/nft -f

flush ruleset

table inet filter {
  chain input {
    type filter hook input priority 0;
    policy drop;

    iif "lo" accept
    ct state established,related accept

    # LAN only
    iifname "eth0" ip saddr 192.168.1.0/24 tcp dport 22 accept
    iifname "eth0" ip saddr 192.168.1.0/24 tcp dport 3000 accept
    iifname "eth0" ip saddr 192.168.1.0/24 udp dport 53 accept
    iifname "eth0" ip saddr 192.168.1.0/24 tcp dport 53 accept

    iifname "eth0" ip saddr 192.168.1.0/24 icmp type echo-request accept
  }
}
NFT
sudo systemctl enable nftables
sudo systemctl restart nftables
sudo nft list ruleset | head -n 40 | sed 's/^/   /'

echo "[D] Tests rapides…"
dig @"${STATIC_IP}" cloudflare.com +short || true
dig @"${STATIC_IP}" ads.google.com +short || true

cat <<EOS

============================================================
✅ Finalisation terminée.

➡️ AdGuard Home:  http://${STATIC_IP}:${ADGUARD_UI_PORT}
   Login: ${ADGUARD_ADMIN_USER} / ${ADGUARD_ADMIN_PASS}
   DNS  : ${STATIC_IP} (port 53)

➡️ Freebox OS → DHCP → DNS :
   - DNS primaire   = ${STATIC_IP}
   - DNS secondaire = 9.9.9.9 (Quad9)

➡️ Suricata (IDS, détection seule) :
   - Logs: /var/log/suricata/fast.log ; /var/log/suricata/eve.json

➡️ Vérifs:
   nslookup google.com ${STATIC_IP}
   nslookup ads.google.com ${STATIC_IP}   # doit être bloqué
============================================================
EOS
