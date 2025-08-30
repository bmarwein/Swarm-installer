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