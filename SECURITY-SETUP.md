# 🔐 SkyOps Swarm — Sécurité d’abord
**Cible :** mettre en place la sécurité **avant** de déployer l’intégralité du Swarm, avec :
- `pi5-security-01` (pare-feu/VPN/DNS filtrant, réseau PRO 10.10.0.0/24)
- `pi3-security-01` → `pi3-security-04` (Wi‑Fi sur LAN perso 192.168.1.0/24), reliés au LAN PRO **via VPN**

> ℹ️ Dans ce guide on considère **LAN perso = 192.168.1.0/24**, **VLAN PRO = 10.10.0.0/24**, **VPN (WG) = 10.20.0.0/24**.  
> Si ton LAN perso est différent, adapte les IP correspondantes.

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

## 1) Netgear (rappel express)
- **VLAN10** : ports des Pi + port vers `pi5-security-01/eth1` = **Untagged**, **PVID=10**.  
- **VLAN1** : retirer (case vide) sur ces ports.  
- **Management VLAN** = 10, IP du switch = **10.10.0.2/24**, GW **10.10.0.1**.  
- Accès admin désormais via `https://10.10.0.2` (depuis le VPN).

---

## 2) `pi5-security-01` – Pare-feu + VPN + DNS filtrant

### 2.1 Vérifs réseau & VPN
```bash
ip -br a
ip route
sudo wg

# tests depuis pi5-security-01
ping -c3 192.168.1.254          # box
ping -c3 10.10.0.11             # un nœud PRO
```

### 2.2 Règles nftables (durcies)
Fichier : **`/etc/nftables.conf`**
```nft
#!/usr/sbin/nft -f
flush ruleset

table inet filter {
  chain input {
    type filter hook input priority 0; policy drop;

    iifname "lo" accept
    ct state established,related accept
    ip protocol icmp icmp type echo-request accept

    # WG en entrée sur WAN
    iifname { "eth0", "wlan0" } udp dport 51820 accept

    # SSH autorisé depuis VPN uniquement
    iifname "wg0" tcp dport 22 accept

    # (Optionnel) fenêtre de maintenance SSH depuis LAN perso
    # iifname "eth0" tcp dport 22 accept

    # Administration locale depuis LAN PRO
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
sudo nft -c -f /etc/nftables.conf   # valider la syntaxe
sudo systemctl restart nftables
sudo nft list ruleset | less
```

### 2.3 CrowdSec (LAPI + bouncer nftables)
```bash
sudo apt update
sudo apt install -y crowdsec crowdsec-firewall-bouncer-nftables

# Vérifier
sudo systemctl status crowdsec
sudo systemctl status crowdsec-firewall-bouncer
sudo cscli metrics
sudo cscli scenarios list | head
```

### 2.4 DNS filtrant (AdGuard Home) pour le VLAN PRO
**Option Docker (recommandée)** – fichier `/opt/adguard/docker-compose.yml` :
```yaml
services:
  adguardhome:
    image: adguard/adguardhome:latest
    container_name: adguardhome
    restart: unless-stopped
    network_mode: host
    volumes:
      - /opt/adguard/work:/opt/adguardhome/work
      - /opt/adguard/conf:/opt/adguardhome/conf
```
Lancer :
```bash
sudo apt install -y docker.io docker-compose-plugin
sudo mkdir -p /opt/adguard/{work,conf}
cd /opt/adguard && sudo docker compose up -d
```

Configurer via `http://10.10.0.1:3000` (wizard) puis **écoute sur 10.10.0.1:53**.  
Sur tes nœuds PRO, mets **DNS = 10.10.0.1** (déjà dans tes scripts).

---

## 3) Étendre le VPN à chaque Pi3 (client WireGuard)
Objectif : que les Pi3 (en Wi‑Fi 192.168.1.x) puissent **atteindre VLAN PRO (10.10.0.x)** via le VPN.

### 3.1 Côté serveur (`pi5-security-01`)
Créer 4 pairs (ex. 10.20.0.10–13) :
```bash
cd /etc/wireguard
for n in 10 11 12 13; do
  wg genkey | tee pi3-$n.key | wg pubkey > pi3-$n.pub
done
```

Ajouter dans `/etc/wireguard/wg0.conf` :
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
Appliquer :
```bash
sudo wg-quick down wg0 && sudo wg-quick up wg0
sudo wg
```

### 3.2 Côté Pi3 (à répéter pour chaque)
Sur le **Pi3-security-01** (ex. 192.168.1.231) :
```bash
sudo apt update && sudo apt install -y wireguard
sudo nano /etc/wireguard/wg0.conf
```
Contenu (adapter clé privée et IP du pair) :
```ini
[Interface]
PrivateKey = <pi3-10.key>
Address = 10.20.0.10/24
DNS = 1.1.1.1

[Peer]
PublicKey = MDX9MQ8FHR92QjKhLVAkR3GcAMi6DKp/pPTtugFDzSc=
Endpoint = 192.168.1.230:51820
AllowedIPs = 10.10.0.0/24,10.20.0.0/24
PersistentKeepalive = 25
```
Activer :
```bash
sudo chmod 600 /etc/wireguard/wg0.conf
sudo systemctl enable wg-quick@wg0
sudo systemctl start wg-quick@wg0
sudo wg
```
Tester :
```bash
ping -c3 10.20.0.1
ping -c3 10.10.0.1
```

---

## 4) Rôles conseillés pour les Pi3 (Wi‑Fi)

### 4.1 `pi3-security-01` → DNS filtrant (AdGuard secondaire)
- IP : **192.168.1.231**
- Wizard via `http://192.168.1.231:3000` → écoute sur **192.168.1.231:53**.  
- Dans ta box, mets **DNS secondaire = 192.168.1.231** (primaire : 1.1.1.1/Quad9).

### 4.2 `pi3-security-02` → Honeypot SSH (Cowrie)
- Installe Cowrie et expose port 2222.  
- Logs : `/opt/cowrie/var/log/`

### 4.3 `pi3-security-03` → Blackbox exporter (sondes Prometheus)
- Probe ICMP/HTTP vers 10.10.x via VPN.  

### 4.4 `pi3-security-04` → CrowdSec agent (remontée signaux)
- `apt install -y crowdsec`  
- Peux être relié à la LAPI de `pi5-security-01` plus tard.  

---

## 5) Vérifications

### Depuis un Pi3
```bash
ping -c3 10.20.0.1
ping -c3 10.10.0.1
```

### Depuis `pi5-security-01`
```bash
sudo wg          # pairs Pi3 doivent avoir un 'latest handshake' récent
```

### Depuis ton Mac (VPN)
```bash
ping 10.10.0.1
ping 10.10.0.11
ssh pi@10.10.0.11
```
