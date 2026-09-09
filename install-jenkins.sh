#!/bin/bash
set -euo pipefail

# ==== Variables avec validation ====
IFACE="${IFACE:-enp0s3}"
JDK_RELEASE="jdk-21.0.12+1"
JDK_API_URL="https://api.adoptium.net/v3/binary/version/${JDK_RELEASE}/linux/x64/jdk/hotspot/normal/eclipse?project=jdk"
JENKINS_REPO_URL="https://pkg.jenkins.io/redhat-stable/jenkins.repo"
JENKINS_KEY_URL="https://pkg.jenkins.io/redhat-stable/jenkins.io-2023.key"
JENKINS_PORT="${JENKINS_PORT:-8080}"
LOG_FILE="/var/log/jenkins-install.log"
MAX_RETRIES=5
RETRY_DELAY=10

# ==== Fonctions utilitaires ====
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

error_exit() {
    log "ERREUR: $*"
    exit 1
}

check_command() {
    command -v "$1" >/dev/null 2>&1 || error_exit "Commande $1 non trouvée"
}

wait_for_service() {
    local port=$1
    local max_attempts=30
    local attempt=0
    
    log "Attente du service sur le port $port..."
    while [ $attempt -lt $max_attempts ]; do
        if curl -sSf -I "http://localhost:${port}" >/dev/null 2>&1; then
            log "Service disponible sur le port $port"
            return 0
        fi
        attempt=$((attempt + 1))
        sleep 2
    done
    return 1
}

retry_download() {
    local url=$1
    local output=$2
    local retries=0
    
    while [ $retries -lt $MAX_RETRIES ]; do
        if curl -fL -o "$output" "$url" --connect-timeout 30 --max-time 300; then
            return 0
        fi
        retries=$((retries + 1))
        log "Tentative $retries/$MAX_RETRIES échouée, nouvelle tentative dans ${RETRY_DELAY}s..."
        sleep $RETRY_DELAY
    done
    return 1
}

# ==== Pré-vérification ====
log "Début de l'installation - Vérification des prérequis"

# Vérification des commandes essentielles
for cmd in curl sed yum systemctl firewall-cmd sha256sum alternatives; do
    check_command "$cmd"
done

# Vérification des droits root
if [ "$EUID" -ne 0 ]; then
    error_exit "Ce script doit être exécuté en tant que root"
fi

# Création du répertoire de logs
mkdir -p "$(dirname "$LOG_FILE")"

# ==== Étape 1: Correction repos CentOS7 EOL ====
log "[1/8] Correction des dépôts CentOS7 EOL"
sudo sed -i.bak \
    -e 's/mirrorlist=/#mirrorlist=/g' \
    -e 's|#baseurl=http://mirror.centos.org|baseurl=http://vault.centos.org|g' \
    /etc/yum.repos.d/CentOS-*.repo 2>/dev/null || log "Aucun repo CentOS trouvé, création du cache"

sudo yum clean all
sudo yum makecache || log "Cache yum créé avec des warnings"

# ==== Étape 2: Réseau avec fallback ====
log "[2/8] Configuration réseau"
if command -v nmcli >/dev/null 2>&1; then
    sudo nmcli connection up "$IFACE" 2>/dev/null || log "Interface $IFACE non trouvée avec nmcli"
else
    ifup "$IFACE" 2>/dev/null || log "Interface $IFACE non trouvée avec ifup"
fi

# Vérification de la connectivité
if ! ping -c 1 -W 5 8.8.8.8 >/dev/null 2>&1; then
    log "ATTENTION: Connectivité réseau limitée, mais on continue..."
fi

# ==== Étape 3: Java 21 Temurin avec gestion avancée ====
log "[3/8] Installation Java 21 Temurin (${JDK_RELEASE})"
cd /opt || error_exit "Impossible d'accéder à /opt"

# Recherche plus robuste du JDK existant
JDK_EXISTING=$(find /opt -maxdepth 1 -type d \( -iname "jdk-21*" -o -iname "temurin-21*" \) 2>/dev/null | head -1)

if [ -z "$JDK_EXISTING" ]; then
    log "Téléchargement du JDK..."
    
    # Récupération de l'URL de téléchargement
    FETCH_URL=$(curl -s -o /dev/null -w '%{redirect_url}' "$JDK_API_URL" --connect-timeout 30) || error_exit "Échec de récupération de l'URL JDK"
    FILENAME=$(basename "$FETCH_URL")
    
    # Téléchargement avec retry
    retry_download "$FETCH_URL" "$FILENAME" || error_exit "Échec du téléchargement JDK"
    
    # Vérification checksum avec meilleure gestion
    log "Vérification du checksum SHA-256"
    retry_download "${FETCH_URL}.sha256.txt" "${FILENAME}.sha256.txt"
    
    # Nettoyage du fichier checksum (peut contenir des espaces)
    sed -i 's/\s.*$//' "${FILENAME}.sha256.txt" 2>/dev/null || true
    
    if sha256sum -c "${FILENAME}.sha256.txt" 2>/dev/null; then
        log "Checksum vérifié avec succès"
    else
        # Tentative de vérification manuelle
        EXPECTED=$(cat "${FILENAME}.sha256.txt")
        ACTUAL=$(sha256sum "$FILENAME" | awk '{print $1}')
        if [ "$EXPECTED" = "$ACTUAL" ]; then
            log "Checksum validé manuellement"
        else
            error_exit "Checksum invalide pour ${FILENAME}"
        fi
    fi
    
    # Extraction avec gestion d'erreur
    log "Extraction du JDK..."
    sudo tar -xzf "$FILENAME" || error_exit "Échec de l'extraction JDK"
    sudo rm -f "$FILENAME" "${FILENAME}.sha256.txt"
else
    log "JDK 21 déjà présent dans ${JDK_EXISTING}, extraction ignorée"
fi

# Détection robuste du JDK
JDK_DIR=$(find /opt -maxdepth 1 -type d \( -iname "jdk-21*" -o -iname "temurin-21*" \) 2>/dev/null | head -1)
[ -z "$JDK_DIR" ] && error_exit "JDK introuvable après installation"

# Configuration alternatives
log "Configuration de Java comme alternative"
if ! alternatives --display java 2>/dev/null | grep -q "$JDK_DIR/bin/java"; then
    sudo alternatives --install /usr/bin/java java "$JDK_DIR/bin/java" 1
fi
sudo alternatives --set java "$JDK_DIR/bin/java" || error_exit "Échec de configuration alternatives"

# Vérification Java
java -version || error_exit "Java non fonctionnel"

# ==== Étape 4: Jenkins avec vérification GPG ====
log "[4/8] Installation de Jenkins"
if [ ! -f /etc/yum.repos.d/jenkins.repo ]; then
    retry_download "$JENKINS_REPO_URL" /etc/yum.repos.d/jenkins.repo || error_exit "Échec téléchargement repo Jenkins"
fi

# Import de la clé GPG avec vérification
if ! rpm -q gpg-pubkey --qf '%{name}-%{version}-%{release}\n' | grep -q jenkins; then
    retry_download "$JENKINS_KEY_URL" /tmp/jenkins-key.asc
    sudo rpm --import /tmp/jenkins-key.asc || error_exit "Échec import clé GPG Jenkins"
    rm -f /tmp/jenkins-key.asc
fi

# Installation avec gestion des dépendances
sudo yum install -y jenkins || error_exit "Échec installation Jenkins"

# Vérification de l'utilisateur jenkins
id jenkins >/dev/null 2>&1 || error_exit "L'utilisateur jenkins n'a pas été créé"

# ==== Étape 5: Configuration systemd avancée ====
log "[5/8] Configuration systemd"
sudo mkdir -p /etc/systemd/system/jenkins.service.d
sudo tee /etc/systemd/system/jenkins.service.d/override.conf > /dev/null <<'EOF'
[Service]
Environment="JENKINS_LISTEN_ADDRESS=0.0.0.0"
Environment="JAVA_OPTS=-Djava.net.preferIPv4Stack=true -Xmx1024m"
Environment="JENKINS_HOME=/var/lib/jenkins"
User=jenkins
Group=jenkins
TimeoutStartSec=600
Restart=on-failure
RestartSec=30
EOF
sudo systemctl daemon-reload

# Configuration des permissions
sudo chown -R jenkins:jenkins /var/lib/jenkins 2>/dev/null || true
sudo chmod 755 /var/lib/jenkins 2>/dev/null || true

# ==== Étape 6: Firewall avancé avec zones ====
log "[6/8] Configuration firewall"
# Vérification de l'existence de l'interface
if ip link show "$IFACE" >/dev/null 2>&1; then
    sudo firewall-cmd --zone=public --add-port="${JENKINS_PORT}/tcp" --permanent || log "Firewall-cmd échoué pour le port"
    sudo firewall-cmd --zone=public --change-interface="$IFACE" --permanent || log "Firewall-cmd échoué pour l'interface"
    sudo firewall-cmd --reload || log "Firewall reload échoué"
else
    log "Interface $IFACE non trouvée, configuration firewall ignorée"
fi

# ==== Étape 7: Activation avec vérification ====
log "[7/8] Activation du service Jenkins"
sudo systemctl enable jenkins || error_exit "Échec activation Jenkins"
sudo systemctl start jenkins || error_exit "Échec démarrage Jenkins"

# ==== Étape 8: Vérification complète ====
log "[8/8] Vérification du déploiement"

# Attente intelligente du service
if wait_for_service "$JENKINS_PORT"; then
    log "✅ Jenkins répond correctement sur le port ${JENKINS_PORT}"
else
    log "❌ ERREUR: Jenkins ne répond pas sur le port ${JENKINS_PORT}"
    log "Affichage du statut Jenkins:"
    sudo systemctl status jenkins --no-pager || true
    log "Affichage des logs Jenkins (dernières 20 lignes):"
    sudo journalctl -u jenkins -n 20 --no-pager || true
    error_exit "Jenkins non fonctionnel"
fi

# Vérification de l'état du service
if systemctl is-active --quiet jenkins; then
    log "✅ Service Jenkins actif"
else
    log "⚠️ Service Jenkins inactif malgré la vérification HTTP"
    sudo systemctl status jenkins --no-pager
fi

# Vérification supplémentaire du mot de passe admin
if [ -f /var/lib/jenkins/secrets/initialAdminPassword ]; then
    log "✅ Mot de passe admin initial disponible"
    ADMIN_PASS=$(sudo cat /var/lib/jenkins/secrets/initialAdminPassword 2>/dev/null | head -1)
    log "📝 Mot de passe admin: $ADMIN_PASS (à conserver)"
else
    log "⚠️ Fichier de mot de passe admin non trouvé"
fi

# Affichage des informations de connexion
log "=== INSTALLATION TERMINÉE ==="
log "🌐 URL: http://$(hostname -I | awk '{print $1}'):${JENKINS_PORT}"
log "🔑 Mot de passe: $ADMIN_PASS"
log "📂 Log: $LOG_FILE"

# Nettoyage
sudo yum clean all 2>/dev/null || true

log "✅ Installation réussie"
exit 0
