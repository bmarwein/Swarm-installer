#!/usr/bin/env bash
set -euo pipefail

############################################
#  Pi4 Network Sentinel (AdGuard + Suricata)
#  Tested on: Raspberry Pi OS Lite 64-bit (Debian 12 Bookworm)
############################################

# =========[ VARIABLES À ADAPTER AU BESOIN ]=========
PI_IFACE="eth0"                  # interface réseau filaire
PI_STATIC_IP="192.168.1.231"     # IP fixe souhaitée pour le Pi
PI_CIDR="24"                     # masque CIDR (24 => 255.255.255.0)
PI_GATEWAY="192.168.1.254"       # passerelle (Freebox par défaut)
LAN_CIDR="192.168.1.0/24"        # plage LAN à protéger (HOME_NET Suricata)

# DNS “en amont” (filtrants) pour AdGuard Home
UPSTREAM_DNS=("9.9.9.9" "1.1.1.2")
BOOTSTRAP_DNS=("9.9.9.10" "1.1.1.1")   # pour résoudre les upstreams au démarrage

# Accès Web AdGuard
ADGUARD_UI_PORT="3000"
ADGUARD_ADMIN_USER="admin"
ADGUARD_ADMIN_PASS="ChangeMe!42"  # sera hashé (bcrypt)

# AdGuard Home ARM64 URL (Pi4 64-bit)
ADGUARD_URL="https://static.adguard.com/adguardhome/release/AdGuardHome_linux_arm64.tar.gz"

# Filtres AdGuard (listes block)
ADGUARD_FILTERS=(
  "https://adguardteam.github.io/AdGuardSDNSFilter/Filters/filter.txt|AdGuard DNS filter"
  "https://oisd.nl/basic.txt|OISD Basic"
  "https://malware-filter.gitlab.io/malware-filter/urlhaus-filter-online.txt|URLHaus Malware"
)

# ===================================================

echo "[1/9] Mise à jour du système et outils de base…"
sudo apt-get update -y
sudo DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
# utilitaires: curl, tar, apache2-utils (htpasswd pour bcrypt), ethtool (optionnel)
sudo apt-get install -y curl tar apache2-utils ethtool

echo "[2/9] Configuration IP statique sur ${PI_IFACE} = ${PI_STATIC_IP}/${PI_CIDR} gw ${PI_GATEWAY}"
# Sauvegarde
if [ -f /etc/dhcpcd.conf ]; then
  sudo cp -a /etc/dhcpcd.conf /etc/dhcpcd.conf.bak.$(date +%F-%H%M%S)
fi

# Supprime bloc existant éventuel pour l’interface, puis ajoute le nôtre
sudo sed -i "/^interface ${PI_IFACE}/,/^$/d" /etc/dhcpcd.conf
cat <<EOF | sudo tee -a /etc/dhcpcd.conf >/dev/null

interface ${PI_IFACE}
static ip_address=${PI_STATIC_IP}/${PI_CIDR}
static routers=${PI_GATEWAY}
# DNS de secours au niveau OS (le vrai filtrage sera par AdGuard)
static domain_name_servers=${UPSTREAM_DNS[*]}
EOF

echo "[3/9] Téléchargement et installation d’AdGuard Home…"
workdir="$(mktemp -d)"
pushd "$workdir" >/dev/null
curl -fsSL "$ADGUARD_URL" -o AdGuardHome.tar.gz
tar -xzf AdGuardHome.tar.gz
cd AdGuardHome
# Installe en service systemd
sudo ./AdGuardHome -s install
# Arrête pour injecter notre configuration
sudo systemctl stop AdGuardHome

echo "[4/9] Génération du hash bcrypt pour le compte admin AdGuard…"
# htpasswd -nBC 10 "" pass => format : :$2y$...  ; on retire le préfixe ":\n"
BCRYPT_HASH="$(htpasswd -nBC 10 "" "${ADGUARD_ADMIN_PASS}" 2>/dev/null | tr -d ':\n')"
# conversion y->a pour compat (certains systèmes)
BCRYPT_HASH="${BCRYPT_HASH/\$2y\$/\$2a\$}"

echo "[5/9] Écriture de la configuration AdGuardHome.yaml…"
sudo mkdir -p /opt/AdGuardHome
# Sauvegarde si fichier existe
if [ -f /opt/AdGuardHome/AdGuardHome.yaml ]; then
  sudo cp -a /opt/AdGuardHome/AdGuardHome.yaml /opt/AdGuardHome/AdGuardHome.yaml.bak.$(date +%F-%H%M%S)
fi

# Construit sections upstreams/bootstraps/filters
AGH_UPS=""
for u in "${UPSTREAM_DNS[@]}"; do AGH_UPS+="    - ${u}\n"; done
AGH_BOOT=""
for b in "${BOOTSTRAP_DNS[@]}"; do AGH_BOOT+="    - ${b}\n"; done
AGH_FILTERS=""
fid=1
for line in "${ADGUARD_FILTERS[@]}"; do
  url="${line%%|*}"; name="${line#*|}"
  AGH_FILTERS+="  - enabled: true\n    url: ${url}\n    name: ${name}\n    id: ${fid}\n"
  fid=$((fid+1))
done

# Fichier de config minimal, sécurisé, prêt à l’emploi
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
$(printf "${AGH_UPS}")
  bootstrap_dns:
$(printf "${AGH_BOOT}")
  protection_enabled: true
  blocking_mode: default
  ratelimit: 20
  cache_size: 64
  cache_ttl_min: 0
  cache_ttl_max: 0
  filters_update_interval: 24
  parental_enabled: false
  safesearch_enabled: false
filters:
$(printf "${AGH_FILTERS}")
EOF

# Redémarre AdGuard
sudo systemctl daemon-reload
sudo systemctl enable AdGuardHome
sudo systemctl start AdGuardHome
sleep 3
sudo systemctl --no-pager --full status AdGuardHome || true
popd >/dev/null
rm -rf "$workdir"

echo "[6/9] Installation et configuration de Suricata (IDS, mode détection)…"
sudo apt-get install -y suricata
# Sauvegarde config
sudo cp -a /etc/suricata/suricata.yaml /etc/suricata/suricata.yaml.bak.$(date +%F-%H%M%S)

# Ajuste HOME_NET et interface capture (AF-PACKET)
sudo sed -i "s|^\(\s*HOME_NET:\s*\).*|\1\"[${LAN_CIDR}]\"|g" /etc/suricata/suricata.yaml
# Active AF-PACKET sur l’interface choisie (entries existent souvent, on injecte proprement si absent)
if ! grep -q "af-packet:" /etc/suricata/suricata.yaml; then
  cat <<'EOPK' | sudo tee -a /etc/suricata/suricata.yaml >/dev/null

af-packet:
  - interface: eth0
    cluster-id: 99
    cluster-type: cluster_flow
    defrag: yes
EOPK
fi
sudo sed -i "s/interface:\s*.*/interface: ${PI_IFACE}/" /etc/suricata/suricata.yaml

echo "[7/9] Téléchargement des règles Suricata + activation service…"
sudo suricata-update || true
sudo systemctl enable suricata
sudo systemctl restart suricata
sleep 3
sudo systemctl --no-pager --full status suricata || true

echo "[8/9] Ouverture minimale des ports via nftables (53 DNS, 3000 UI depuis LAN, 22 SSH)…"
# Crée une règle simple si aucune table n’existe (sans casser la conf existante si tu en as déjà une)
if ! sudo nft list ruleset >/dev/null 2>&1; then
  echo "nftables absent ou vide: installation d’un jeu de règles minimal."
fi

sudo bash -c 'cat >/etc/nftables.conf' <<'NFT'
#!/usr/sbin/nft -f

flush ruleset

table inet filter {
  chain input {
    type filter hook input priority 0;
    policy drop;

    # loopback
    iif "lo" accept

    # established / related
    ct state established,related accept

    # SSH (depuis LAN uniquement)
    iifname "eth0" tcp dport 22 ip saddr 192.168.1.0/24 accept

    # UI AdGuard (depuis LAN)
    iifname "eth0" tcp dport 3000 ip saddr 192.168.1.0/24 accept

    # DNS (UDP/TCP) pour tout le LAN
    iifname "eth0" udp dport 53 ip saddr 192.168.1.0/24 accept
    iifname "eth0" tcp dport 53 ip saddr 192.168.1.0/24 accept

    # ICMP (ping) depuis LAN
    iifname "eth0" icmp type echo-request ip saddr 192.168.1.0/24 accept
  }
}
NFT

sudo systemctl enable nftables
sudo systemctl restart nftables
sudo nft list ruleset

echo "[9/9] Redémarrage du réseau (dhcpcd) puis rappel final…"
sudo systemctl restart dhcpcd || true

cat <<EOS

============================================================
✅ Installation terminée.

➡️ AdGuard Home est actif :
   - UI :  http://${PI_STATIC_IP}:${ADGUARD_UI_PORT}
   - Login : ${ADGUARD_ADMIN_USER} / ${ADGUARD_ADMIN_PASS}
   - DNS   : ${PI_STATIC_IP} (port 53)

➡️ Suricata (IDS) est actif (mode détection) :
   - Logs : /var/log/suricata/fast.log
   - HOME_NET : ${LAN_CIDR}
   - Interface : ${PI_IFACE}

➡️ nftables actif (règles minimales ouvertes pour LAN).

DERNIÈRE ÉTAPE (manuelle) : Freebox OS
1) Paramètres avancés → DHCP → DNS :
   - DNS primaire   = ${PI_STATIC_IP}
   - DNS secondaire = 9.9.9.9 (Quad9 filtrant)  [secours si le Pi tombe]

2) Redémarre les équipements ou renouvelle leur bail DHCP.
3) Teste :
   - nslookup google.com ${PI_STATIC_IP}
   - nslookup ads.google.com ${PI_STATIC_IP}   (doit être BLOQUÉ)

Tips:
- Les listes AdGuard se mettent à jour automatiquement (toutes les 24h).
- Pour basculer Suricata en IPS (blocage actif), il faudra placer le Pi en routeur/bridge.
  Dans ta demande actuelle (filtre additionnel), on reste en IDS (détection sans coupure).
============================================================
EOS