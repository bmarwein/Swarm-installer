#!/usr/bin/env bash
set -euo pipefail

############################################################
#  Pi5 Security Node - RESET & REBUILD (AdGuard + Suricata)
#  OS: Raspberry Pi OS 64-bit (Debian 12 Bookworm)
#  Objectif: repartir (presque) de zéro et réinstaller proprement
############################################################

### ⚠️ AVERTISSEMENTS
# - Branche le Pi EN ETHERNET avant d'exécuter: le Wi-Fi sera désactivé.
# - Ce script purge d'anciennes installations potentielles (Pi-hole, AdGuard, Unbound, dnsmasq, Suricata)
#   et remplace tes règles pare-feu par un jeu minimal.

# =========[ VARIABLES À ADAPTER ]=========
HOSTNAME_NEW="pi5-security-01"

IFACE="eth0"                    # interface filaire
STATIC_IP="192.168.1.231"       # IP fixe du Pi sécurité
CIDR="24"                       # masque /24 => 255.255.255.0
GATEWAY="192.168.1.254"         # Freebox
LAN_CIDR="192.168.1.0/24"       # réseau domestique

# DNS “amont” pour AdGuard (filtrants)
UPSTREAM_DNS=("9.9.9.9" "1.1.1.2")
BOOTSTRAP_DNS=("9.9.9.10" "1.1.1.1")

# Accès Web AdGuard
ADGUARD_UI_PORT="3000"
ADGUARD_ADMIN_USER="admin"
ADGUARD_ADMIN_PASS="ChangeMe!42"   # change-le après installation

# Binaire AdGuard (ARM64 pour Pi5)
ADGUARD_URL="https://static.adguard.com/adguardhome/release/AdGuardHome_linux_arm64.tar.gz"

# Listes de blocage à activer
ADGUARD_FILTERS=(
  "https://adguardteam.github.io/AdGuardSDNSFilter/Filters/filter.txt|AdGuard DNS filter"
  "https://oisd.nl/basic.txt|OISD Basic"
  "https://malware-filter.gitlab.io/malware-filter/urlhaus-filter-online.txt|URLHaus Malware"
)

# ========================================================

bold(){ echo -e "\e[1m$*\e[0m"; }
ok(){ echo -e "\e[32m✔\e[0m $*"; }
warn(){ echo -e "\e[33m▲\e[0m $*"; }
err(){ echo -e "\e[31m✘\e[0m $*"; }

bold "Pi5 Security Node - RESET & REBUILD"
echo "Interface: $IFACE  IP: $STATIC_IP/$CIDR  GW: $GATEWAY  LAN: $LAN_CIDR"
sleep 1

############################################
# 1) Mise à jour système et outils
############################################
bold "[1/9] Mises à jour & outils…"
apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
apt-get install -y curl tar apache2-utils ethtool jq nftables net-tools

############################################
# 2) Désactivation Wi-Fi & Bluetooth (perso/production)
############################################
bold "[2/9] Désactivation Wi-Fi/BT (reboot requis pour effet complet)…"
# Bookworm: config.txt sous /boot/firmware
BOOTCFG="/boot/firmware/config.txt"
if [ -f "$BOOTCFG" ]; then
  cp -a "$BOOTCFG" "${BOOTCFG}.bak.$(date +%F-%H%M%S)"
  grep -q "^dtoverlay=disable-wifi" "$BOOTCFG" || echo "dtoverlay=disable-wifi" >> "$BOOTCFG"
  grep -q "^dtoverlay=disable-bt" "$BOOTCFG"   || echo "dtoverlay=disable-bt" >> "$BOOTCFG"
fi
systemctl disable --now wpa_supplicant.service || true
systemctl mask wpa_supplicant.service || true
rfkill block wifi || true
rfkill block bluetooth || true
ok "Wi-Fi/BT désactivés (prend effet total après reboot)."

############################################
# 3) Purge d'anciennes installations/confs
############################################
bold "[3/9] Purge des anciennes installations (AdGuard/Pi-hole/Unbound/dnsmasq/Suricata)…"
# Stop services possibles
systemctl stop AdGuardHome 2>/dev/null || true
systemctl disable AdGuardHome 2>/dev/null || true
systemctl stop pihole-FTL 2>/dev/null || true
systemctl disable pihole-FTL 2>/dev/null || true
systemctl stop unbound 2>/dev/null || true
systemctl disable unbound 2>/dev/null || true
systemctl stop dnsmasq 2>/dev/null || true
systemctl disable dnsmasq 2>/dev/null || true
systemctl stop suricata 2>/dev/null || true
systemctl disable suricata 2>/dev/null || true

# Purge paquets
apt-get purge -y adguardhome || true
apt-get purge -y pihole || true
apt-get purge -y unbound || true
apt-get purge -y dnsmasq || true
apt-get purge -y suricata || true
apt-get autoremove -y

# Suppression traces/conf
rm -rf /opt/AdGuardHome /etc/pihole /etc/dnsmasq.d /var/lib/misc/dnsmasq.leases
rm -rf /etc/unbound /var/lib/unbound
rm -rf /etc/suricata /var/log/suricata
rm -f /etc/systemd/system/AdGuardHome.service
systemctl daemon-reload

# Réinitialise nftables à blanc (on remettra un set minimal ensuite)
nft flush ruleset 2>/dev/null || true
ok "Purge effectuée."

############################################
# 4) Réglage hostname (optionnel)
############################################
bold "[4/9] Hostname…"
current_hn=$(hostname)
if [ "$current_hn" != "$HOSTNAME_NEW" ]; then
  hostnamectl set-hostname "$HOSTNAME_NEW"
  sed -i "s/127.0.1.1.*/127.0.1.1\t$HOSTNAME_NEW/g" /etc/hosts || true
  ok "Hostname changé: $current_hn -> $HOSTNAME_NEW"
else
  ok "Hostname déjà: $HOSTNAME_NEW"
fi

############################################
# 5) IP statique sur l’interface filaire (NetworkManager OU dhcpcd)
############################################
bold "[5/9] IP statique sur $IFACE…"

if command -v nmcli >/dev/null 2>&1; then
  # ===== NetworkManager (Bookworm par défaut) =====
  # Crée/replace une connexion statique "eth0-static"
  if nmcli -t -f NAME connection show | grep -Fxq "eth0-static"; then
    nmcli con mod eth0-static ipv4.addresses "${STATIC_IP}/${CIDR}" \
      ipv4.gateway "${GATEWAY}" \
      ipv4.dns "9.9.9.9,1.1.1.2" \
      ipv4.method manual ipv6.method ignore autoconnect yes
  else
    nmcli con add type ethernet ifname "${IFACE}" con-name eth0-static \
      ipv4.addresses "${STATIC_IP}/${CIDR}" \
      ipv4.gateway "${GATEWAY}" \
      ipv4.dns "9.9.9.9,1.1.1.2" \
      ipv4.method manual ipv6.method ignore autoconnect yes
  fi

  # Supprime éventuelle connexion DHCP conflictuelle
  # (les noms varient: "Wired connection 1", "eth0"…)
  for C in $(nmcli -t -f NAME,TYPE c s | awk -F: '$2=="ethernet"{print $1}'); do
    if [ "$C" != "eth0-static" ]; then nmcli con delete "$C" 2>/dev/null || true; fi
  done

  nmcli con up eth0-static || true
  sleep 2
  ok "IP statique appliquée via NetworkManager (${STATIC_IP}/${CIDR}, gw ${GATEWAY})."

elif [ -f /etc/dhcpcd.conf ]; then
  # ===== Ancien modèle dhcpcd =====
  cp -a /etc/dhcpcd.conf /etc/dhcpcd.conf.bak.$(date +%F-%H%M%S)
  sed -i "/^interface ${IFACE}/,\$d" /etc/dhcpcd.conf
  cat <<EOF >> /etc/dhcpcd.conf

interface ${IFACE}
static ip_address=${STATIC_IP}/${CIDR}
static routers=${GATEWAY}
static domain_name_servers=9.9.9.9 1.1.1.2
EOF
  systemctl restart dhcpcd || true
  sleep 2
  ok "IP statique appliquée via dhcpcd (${STATIC_IP}/${CIDR}, gw ${GATEWAY})."

else
  warn "Ni NetworkManager (nmcli) ni dhcpcd détecté. Installe NM : apt-get install -y network-manager"
  exit 1
fi

############################################
# 6) Installation AdGuard Home (propre)
############################################
bold "[6/9] Installation AdGuard Home…"
WORKDIR="$(mktemp -d)"
pushd "$WORKDIR" >/dev/null
curl -fsSL "$ADGUARD_URL" -o AdGuardHome.tar.gz
tar -xzf AdGuardHome.tar.gz
cd AdGuardHome
./AdGuardHome -s install
systemctl stop AdGuardHome

# Génération du hash bcrypt
BCRYPT_HASH="$(htpasswd -nBC 10 "" "${ADGUARD_ADMIN_PASS}" 2>/dev/null | tr -d ':\n')"
BCRYPT_HASH="${BCRYPT_HASH/\$2y\$/\$2a\$}"

# Construire YAML
UPS=""; for u in "${UPSTREAM_DNS[@]}";   do UPS+="    - ${u}\n"; done
BOOT=""; for b in "${BOOTSTRAP_DNS[@]}"; do BOOT+="    - ${b}\n"; done
FILS=""; fid=1
for line in "${ADGUARD_FILTERS[@]}"; do
  url="${line%%|*}"; name="${line#*|}"
  FILS+="  - enabled: true\n    url: ${url}\n    name: ${name}\n    id: ${fid}\n"
  fid=$((fid+1))
done

mkdir -p /opt/AdGuardHome
cat <<EOF > /opt/AdGuardHome/AdGuardHome.yaml
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

systemctl daemon-reload
systemctl enable AdGuardHome
systemctl start AdGuardHome
sleep 2
systemctl --no-pager --full status AdGuardHome || true
popd >/dev/null
rm -rf "$WORKDIR"
ok "AdGuard Home opérationnel: http://${STATIC_IP}:${ADGUARD_UI_PORT}"

############################################
# 7) Installation Suricata (IDS)
############################################
bold "[7/9] Installation & config Suricata (IDS mode)…"
apt-get install -y suricata
cp -a /etc/suricata/suricata.yaml /etc/suricata/suricata.yaml.bak.$(date +%F-%H%M%S)
sed -i "s|^\(\s*HOME_NET:\s*\).*|\1\"[${LAN_CIDR}]\"|g" /etc/suricata/suricata.yaml

# Ajout AF-PACKET si absent, puis forcer interface
if ! grep -q "af-packet:" /etc/suricata/suricata.yaml; then
cat <<'EOPK' >> /etc/suricata/suricata.yaml

af-packet:
  - interface: eth0
    cluster-id: 99
    cluster-type: cluster_flow
    defrag: yes
EOPK
fi
sed -i "s/interface:\s*.*/interface: ${IFACE}/" /etc/suricata/suricata.yaml

suricata-update || true
systemctl enable suricata
systemctl restart suricata
sleep 2
systemctl --no-pager --full status suricata || true
ok "Suricata en mode détection. Logs: /var/log/suricata/"

############################################
# 8) Pare-feu nftables minimal (réécrit)
############################################
bold "[8/9] Règles nftables minimales (LAN uniquement)…"
cat >/etc/nftables.conf <<'NFT'
#!/usr/sbin/nft -f

flush ruleset

table inet filter {
  chain input {
    type filter hook input priority 0;
    policy drop;

    # loopback
    iif "lo" accept

    # established/related
    ct state established,related accept

    # Autoriser depuis LAN uniquement
    iifname "eth0" ip saddr 192.168.1.0/24 tcp dport 22 accept        # SSH
    iifname "eth0" ip saddr 192.168.1.0/24 tcp dport 3000 accept      # UI AdGuard
    iifname "eth0" ip saddr 192.168.1.0/24 udp dport 53 accept        # DNS
    iifname "eth0" ip saddr 192.168.1.0/24 tcp dport 53 accept        # DNS

    # ICMP ping depuis LAN
    iifname "eth0" ip saddr 192.168.1.0/24 icmp type echo-request accept
  }
}
NFT
systemctl enable nftables
systemctl restart nftables
nft list ruleset | sed 's/^/   /' | head -n 40
ok "Pare-feu appliqué."

############################################
# 9) Récapitulatif + instructions Freebox
############################################
bold "[9/9] Terminé ✅"
echo " • Hostname           : $HOSTNAME_NEW"
echo " • Interface          : $IFACE"
echo " • IP fixe            : $STATIC_IP/$CIDR  (GW $GATEWAY)"
echo " • AdGuard UI         : http://${STATIC_IP}:${ADGUARD_UI_PORT} (user=${ADGUARD_ADMIN_USER} / pass=${ADGUARD_ADMIN_PASS})"
echo " • DNS (à déclarer)   : ${STATIC_IP} (port 53)"
echo " • Upstreams          : ${UPSTREAM_DNS[*]}  | Bootstrap: ${BOOTSTRAP_DNS[*]}"
echo " • Suricata (IDS)     : /var/log/suricata/  (fast.log, eve.json)"
echo " • nftables           : /etc/nftables.conf"

cat <<'EOS'

Dernière étape côté Freebox OS :
1) Paramètres avancés → DHCP → DNS
   - DNS primaire   = [IP du Pi sécurité] (ex: 192.168.1.231)
   - DNS secondaire = 9.9.9.9 (Quad9 filtrant)

2) Renouvelle le bail DHCP de tes appareils ou redémarre-les.

3) Tests rapides:
   - nslookup google.com 192.168.1.231
   - nslookup ads.google.com 192.168.1.231   (doit être bloqué)

NOTE: Le Wi-Fi/BT est désactivé et nécessite un reboot pour effet complet:
   sudo reboot
EOS

ok "Reset & rebuild effectués. Tu peux redémarrer le Pi maintenant."
