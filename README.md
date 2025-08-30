# 🚀 SkyOps Swarm – Guideline d’installation des nodes

Ce document décrit les **étapes à suivre pour préparer et intégrer chaque node** (Pi ou miniPC) dans le cluster **VLAN10 (10.10.0.0/24)** derrière le firewall `pi5-security-01`.

---

## 1️⃣ Pré-requis

- Carte SD flashée avec Raspberry Pi OS (Bookworm recommandé).
- SSH activé et Wi-Fi configuré pour premier accès (192.168.1.x).
- Câble Ethernet du node branché au switch Netgear sur un port **VLAN10 Untagged + PVID=10**.
- Sur le node : accès SSH en Wi-Fi (192.168.1.x).

---

## 2️⃣ Bootstrap réseau (Wi-Fi → ETH VLAN10)

Sur le node (via Wi-Fi) :

```bash
cd ~/Swarm-installer
sudo ./bootstrap-wifi-to-eth.sh --wifi-backup
```

- L’IP fixe VLAN10 est attribuée automatiquement selon le **hostname** (`/etc/hostname`).
- Le Wi-Fi reste actif en secours, mais **sans gateway**.

---

## 3️⃣ Vérifications sur le node

```bash
# IP et routes
ip a show eth0
ip route

# Vérifier la gateway
ping -c3 10.10.0.1

# Vérifier ARP de la gateway
ip neigh show 10.10.0.1

# (Optionnel) ping d’un autre node déjà configuré
ping -c3 10.10.0.11
```

👉 Attendu :  
- IP fixe correcte (ex: `10.10.0.12/24`)  
- Default route via `10.10.0.1`  
- Ping de la gateway OK (<1ms)  

---

## 4️⃣ Vérifications depuis le firewall (`pi5-security-01`)

```bash
# Vérifier ARP et ping du nouveau node
ip neigh show | grep 10.10.0.
ping -c3 <IP_NODE>
```

👉 Attendu : ARP résolu + ping OK.

---

## 5️⃣ Vérifications depuis un manager déjà en place (ex: `pi5-master-01`)

```bash
ping -c3 <IP_NODE>
```

👉 Attendu : ping OK.

---

## 6️⃣ Checklist d’intégration

- [ ] Node démarré et accessible en Wi-Fi  
- [ ] Script `bootstrap-wifi-to-eth.sh` exécuté  
- [ ] IP statique VLAN10 correcte  
- [ ] Ping gateway (10.10.0.1) OK  
- [ ] Ping croisé avec au moins 1 manager OK  
- [ ] ARP visible depuis le firewall  
- [ ] (Optionnel) désactivation définitive du Wi-Fi quand tout est stable :  
  ```bash
  nmcli con show
  sudo nmcli con mod <wifi_profile> connection.autoconnect no
  sudo nmcli con down <wifi_profile>
  ```

---

## 7️⃣ Attribution des IPs par hostname

| Rôle         | Hostname         | IP fixe    |
|--------------|------------------|------------|
| Gateway      | pi5-security-01  | 10.10.0.1  |
| Master 1     | mpc-manager-01   | 10.10.0.10 |
| Master 2     | pi5-master-01    | 10.10.0.11 |
| Master 3     | pi5-master-02    | 10.10.0.12 |
| Worker Pi5   | pi5-worker-01    | 10.10.0.21 |
| Worker Pi5   | pi5-worker-02    | 10.10.0.22 |
| Worker Pi4   | pi4-worker-01    | 10.10.0.31 |
| Worker Pi4   | pi4-worker-02    | 10.10.0.32 |
| Worker Pi4   | pi4-worker-03    | 10.10.0.33 |
| Worker Pi4   | pi4-worker-04    | 10.10.0.34 |

---

## ✅ Conclusion

À la fin de cette procédure, le node fait partie du réseau VLAN10 et peut être intégré dans le cluster Docker Swarm.
