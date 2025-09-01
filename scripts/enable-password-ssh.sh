#!/usr/bin/env bash
set -euo pipefail

# --- helpers ---
green(){ printf "\033[1;32m%s\033[0m\n" "$*"; }
yellow(){ printf "\033[1;33m%s\033[0m\n" "$*"; }
red(){ printf "\033[1;31m%s\033[0m\n" "$*"; }

require_root(){
  if [ "$(id -u)" -ne 0 ]; then
    red "Ce script doit être lancé en root (sudo)."
    exit 1
  fi
}

backup_file(){
  local f="$1"
  if [ -f "$f" ]; then
    cp -an "$f" "${f}.bak.$(date +%Y%m%d-%H%M%S)"
  fi
}

ensure_kv(){
  # ensure_kv <file> <Directive> <value>
  local file="$1" key="$2" val="$3"
  if grep -Eq "^\s*${key}\s+" "$file"; then
    sed -i -E "s|^\s*${key}\s+.*|${key} ${val}|g" "$file"
  else
    printf "%s %s\n" "$key" "$val" >> "$file"
  fi
}

enable_service(){
  local svc="$1"
  systemctl enable "$svc" >/dev/null 2>&1 || true
  systemctl restart "$svc"
  systemctl --no-pager --full status "$svc" | sed -n '1,5p' || true
}

# --- start ---
require_root
green "==> Activation SSH + auth mot de passe + Fail2ban (mode idempotent)"

# 1) SSHD
SSHD_CFG="/etc/ssh/sshd_config"
if [ ! -f "$SSHD_CFG" ]; then
  red "Fichier $SSHD_CFG introuvable. Est-ce bien un OS avec OpenSSH serveur ?"
  exit 1
fi

yellow "-- sauvegarde sshd_config"
backup_file "$SSHD_CFG"

yellow "-- mise à jour des directives sshd"
ensure_kv "$SSHD_CFG" "Port" "22"
ensure_kv "$SSHD_CFG" "PermitRootLogin" "no"
ensure_kv "$SSHD_CFG" "PasswordAuthentication" "yes"
ensure_kv "$SSHD_CFG" "ChallengeResponseAuthentication" "no"
ensure_kv "$SSHD_CFG" "UsePAM" "yes"
ensure_kv "$SSHD_CFG" "PubkeyAuthentication" "no"
ensure_kv "$SSHD_CFG" "StrictModes" "yes"

yellow "-- (ré)activation du service ssh"
systemctl daemon-reload || true
enable_service ssh || enable_service sshd || true

# 2) Fail2ban
yellow "-- installation de fail2ban"
DEBIAN_FRONTEND=noninteractive apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get install -y fail2ban

# Crée le dossier jail.d si besoin
mkdir -p /etc/fail2ban/jail.d

# Déploye la conf sshd si présente dans le repo (attendue au même chemin relatif)
REPO_SSH_LOCAL="$(dirname "$0")/fail2ban/jail.d/ssh.local"
if [ -f "$REPO_SSH_LOCAL" ]; then
  yellow "-- déploiement de la conf fail2ban ssh.local"
  cp -f "$REPO_SSH_LOCAL" /etc/fail2ban/jail.d/ssh.local
else
  yellow "-- aucune conf locale trouvée, on génère une conf par défaut"
  cat >/etc/fail2ban/jail.d/ssh.local <<'EOF'
[sshd]
enabled = true
port    = ssh
logpath = %(sshd_log)s
backend = systemd

# Durcit un peu :
maxretry = 5
findtime = 10m
bantime  = 1h
banaction = iptables-multiport
EOF
fi

yellow "-- (ré)activation de fail2ban"
enable_service fail2ban

# 3) Affichage d'infos utiles
IPV4=$(hostname -I 2>/dev/null | awk '{print $1}')
green "==> Terminé."
echo "Host:       $(hostname)"
echo "Adresse IP: ${IPV4:-inconnue}"
echo "SSH:        Port 22, mot de passe activé, clés désactivées"
echo "Fail2ban:   actif (jail [sshd])"
echo
echo "Tests rapides :"
echo "  ssh $(whoami)@${IPV4}    # depuis une autre machine du LAN"
echo "  sudo fail2ban-client status"
echo "  sudo fail2ban-client status sshd"
