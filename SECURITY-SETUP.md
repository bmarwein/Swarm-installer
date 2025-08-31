# 🔐 SkyOps Swarm — Sécurité d’abord
**Objectif :** mettre en place la sécurité **avant** de déployer l’intégralité du Swarm, avec :  
- `pi5-security-01` (pare-feu/VPN/DNS filtrant, réseau PRO 10.10.0.0/24)  
- `pi3-security-01` → `pi3-security-04` (Wi‑Fi sur LAN perso 192.168.1.0/24), reliés au LAN PRO via VPN  

---

## 0) Plan IP & noms
| Rôle | Hostname | Interface | IP |
|---|---|---|---|
| Firewall/GW | `pi5-security-01` | `eth0` (WAN) | 192.168.1.230 |
|  |  | `wlan0` (WAN backup) | 192.168.1.x (DHCP) |
|  |  | `eth1` (LAN PRO) | **10.10.0.1/24** |
|  |  | `wg0` (VPN) | **10.20.0.1/24** |
| Switch mgmt | Netgear manageable | Mgmt VLAN10 | **10.10.0.2/24** |
| Manager 1 | `pi5-master-01` | `eth0` | **10.10.0.11/24** |
| Pi3 sec | `pi3-security-01` | `wlan0` | **192.168.1.231/24** |
| Pi3 sec | `pi3-security-02` | `wlan0` | **192.168.1.232/24** |
| Pi3 sec | `pi3-security-03` | `wlan0` | **192.168.1.233/24** |
| Pi3 sec | `pi3-security-04` | `wlan0` | **192.168.1.234/24** |

---

## 1) Netgear (rappel)
- **VLAN10** : ports Pi + port vers `pi5-security-01/eth1` = Untagged, PVID=10.  
- **VLAN1** : retirer (case vide) sur ces ports.  
- **Management VLAN** = 10, IP = 10.10.0.2/24, GW=10.10.0.1.  
- Accès admin via `https://10.10.0.2` (depuis VPN).

---

## 2) `pi5-security-01` (Firewall / VPN / DNS)

### 2.1 Vérifs réseau & VPN
```bash
ip -br a
ip route
sudo wg
ping -c3 192.168.1.254   # box
ping -c3 10.10.0.11      # un nœud PRO
```

### 2.2 nftables (pare-feu)
Créer `/etc/nftables.conf` :
```nft
#!/usr/sbin/nft -f
flush ruleset

table inet filter {
  chain input {
    type filter hook input priority 0; policy drop;

    iifname "lo" accept
    ct state established,related accept
    ip protocol icmp icmp type echo-request accept

    # WireGuard
    iifname { "eth0","wlan0" } udp dport 51820 accept

    # SSH seulement via VPN
    iifname "wg0" tcp dport 22 accept

    # Admin local VLAN PRO
    iifname "eth1" accept
  }

  chain forward {
    type filter hook forward priority 0; policy drop;
    ct state established,related accept

    # LAN PRO -> WAN
    iifname "eth1" oifname { "eth0","wlan0" } accept

    # VPN -> LAN PRO
    iifname "wg0" oifname "eth1" accept
  }
}

table ip nat {
  chain postrouting {
    type nat hook postrouting priority 100;
    oifname "eth0" masquerade
    oifname "wlan0" masquerade
  }
}
```
Appliquer :
```bash
sudo nft -c -f /etc/nftables.conf
sudo systemctl restart nftables
```

### 2.3 CrowdSec
```bash
sudo apt install -y crowdsec crowdsec-firewall-bouncer-nftables
sudo systemctl status crowdsec
sudo cscli metrics
```

### 2.4 AdGuard Home (DNS filtrant VLAN PRO)
```bash
sudo apt install -y docker.io docker-compose-plugin
sudo mkdir -p /opt/adguard/{work,conf}
cd /opt/adguard

cat <<'YML' | sudo tee docker-compose.yml
services:
  adguardhome:
    image: adguard/adguardhome:latest
    container_name: adguardhome
    restart: unless-stopped
    network_mode: host
    volumes:
      - /opt/adguard/work:/opt/adguardhome/work
      - /opt/adguard/conf:/opt/adguardhome/conf
YML

sudo docker compose up -d
```
Configurer via `http://10.10.0.1:3000` → écoute sur 10.10.0.1:53.  
DNS des nœuds PRO = 10.10.0.1.

---

## 3) WireGuard (étendre aux Pi3)
### 3.1 Générer les pairs sur `pi5-security-01`
```bash
cd /etc/wireguard
for n in 10 11 12 13; do
  wg genkey | tee pi3-$n.key | wg pubkey > pi3-$n.pub
done
```
Ajouter dans `wg0.conf` :
```ini
# Pi3-sec-01
[Peer]
PublicKey = <pi3-10.pub>
AllowedIPs = 10.20.0.10/32

# Pi3-sec-02
[Peer]
PublicKey = <pi3-11.pub>
AllowedIPs = 10.20.0.11/32

# Pi3-sec-03
[Peer]
PublicKey = <pi3-12.pub>
AllowedIPs = 10.20.0.12/32

# Pi3-sec-04
[Peer]
PublicKey = <pi3-13.pub>
AllowedIPs = 10.20.0.13/32
```
Redémarrer :
```bash
sudo wg-quick down wg0 && sudo wg-quick up wg0
```

### 3.2 Config client Pi3 (exemple Pi3-sec-01)
`/etc/wireguard/wg0.conf` :
```ini
[Interface]
PrivateKey = <pi3-10.key>
Address = 10.20.0.10/24
DNS = 1.1.1.1

[Peer]
PublicKey = <public key du serveur>
Endpoint = 192.168.1.230:51820
AllowedIPs = 10.10.0.0/24,10.20.0.0/24
PersistentKeepalive = 25
```
Activer :
```bash
sudo chmod 600 /etc/wireguard/wg0.conf
sudo systemctl enable wg-quick@wg0
sudo systemctl start wg-quick@wg0
```

---

## 4) Rôles détaillés des Pi3

### 4.1 `pi3-security-01` → DNS filtrant (AdGuard secondaire)
```bash
sudo apt install -y docker.io docker-compose-plugin
sudo mkdir -p /opt/adguard/{work,conf}
cd /opt/adguard

cat <<'YML' | sudo tee docker-compose.yml
services:
  adguardhome:
    image: adguard/adguardhome:latest
    container_name: adguardhome
    restart: unless-stopped
    network_mode: host
    volumes:
      - /opt/adguard/work:/opt/adguardhome/work
      - /opt/adguard/conf:/opt/adguardhome/conf
YML

sudo docker compose up -d
```
- Accès : `http://192.168.1.231:3000`  
- Mets DNS secondaire de ta box = `192.168.1.231`.  

### 4.2 `pi3-security-02` → Honeypot SSH (Cowrie)
```bash
sudo apt update && sudo apt install -y python3-venv git
git clone https://github.com/cowrie/cowrie.git /opt/cowrie
cd /opt/cowrie
python3 -m venv cowrie-env
source cowrie-env/bin/activate
pip install -r requirements.txt
cp etc/cowrie.cfg.dist etc/cowrie.cfg
nano etc/cowrie.cfg   # listen_endpoints = tcp:2222:interface=0.0.0.0
bin/cowrie start
```
Logs : `/opt/cowrie/var/log/`

### 4.3 `pi3-security-03` → Blackbox Exporter
```bash
sudo apt install -y docker.io docker-compose-plugin
mkdir -p /opt/blackbox && cd /opt/blackbox

cat <<'YML' | sudo tee docker-compose.yml
services:
  blackbox:
    image: prom/blackbox-exporter:latest
    container_name: blackbox
    restart: unless-stopped
    network_mode: host
    volumes:
      - ./blackbox.yml:/etc/blackbox_exporter/config.yml:ro
YML

cat <<'CFG' | sudo tee blackbox.yml
modules:
  icmp:
    prober: icmp
  http_2xx:
    prober: http
CFG

sudo docker compose up -d
```
Tester :
```bash
curl "http://127.0.0.1:9115/probe?target=10.10.0.1&module=icmp"
```

### 4.4 `pi3-security-04` → CrowdSec agent
```bash
sudo apt update && sudo apt install -y crowdsec
sudo systemctl status crowdsec
sudo cscli metrics
sudo cscli decisions list
```

---

## 5) Vérifications

### Depuis un Pi3
```bash
ping -c3 10.20.0.1
ping -c3 10.10.0.1
```

### Depuis `pi5-security-01`
```bash
sudo wg   # pairs doivent avoir un 'latest handshake'
```

### Depuis ton Mac (VPN)
```bash
ping 10.10.0.1
ping 10.10.0.11
ssh pi@10.10.0.11
```
