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
    local http_code

    log "Attente du service sur le port $port..."
    while [ $attempt -lt $max_attempts ]; do
        http_code=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 3 "http://localhost:${port}" 2>/dev/null || echo "000")
        if [ "$http_code" != "000" ]; then
            log "Service disponible sur le port $port (code HTTP: $http_code)"
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

# ============================================================
# ==== SECTION ADDITIVE : INSTALLATION DE SONARQUBE        ====
# ============================================================
# Cette section est indépendante de la partie Jenkins ci-dessus.
# Elle installe SonarQube Community Build sur la même VM,
# avec son propre user système, son propre service systemd,
# et son propre port (9000 par défaut).

# ==== Variables SonarQube ====
SONARQUBE_VERSION="${SONARQUBE_VERSION:-26.8.0.126808}"
SONARQUBE_ZIP_URL="https://binaries.sonarsource.com/Distribution/sonarqube/sonarqube-${SONARQUBE_VERSION}.zip"
SONARQUBE_HOME="/opt/sonarqube"
SONARQUBE_PORT="${SONARQUBE_PORT:-9000}"
SONARQUBE_USER="sonarqube"
SONARQUBE_TMP_DIR="/tmp/sonarqube-install"

log "=== DÉBUT INSTALLATION SONARQUBE ==="

# ==== SQ Étape 1: Réglages système requis (vm.max_map_count + ulimits) ====
log "[SQ 1/9] Réglages système (vm.max_map_count, ulimits)"

if ! grep -q "^vm.max_map_count" /etc/sysctl.conf 2>/dev/null; then
    echo "vm.max_map_count=262144" | sudo tee -a /etc/sysctl.conf >/dev/null
fi
sudo sysctl -w vm.max_map_count=262144 || log "ATTENTION: échec sysctl vm.max_map_count"

sudo mkdir -p /etc/security/limits.d
if [ ! -f /etc/security/limits.d/99-sonarqube.conf ]; then
    sudo tee /etc/security/limits.d/99-sonarqube.conf > /dev/null <<EOF
${SONARQUBE_USER}   -   nofile   65536
${SONARQUBE_USER}   -   nproc    4096
EOF
fi

# ==== SQ Étape 2: Création du user système sonarqube ====
log "[SQ 2/9] Création du user système ${SONARQUBE_USER}"
if ! id "$SONARQUBE_USER" >/dev/null 2>&1; then
    sudo useradd -r -m -d "$SONARQUBE_HOME" -s /sbin/nologin "$SONARQUBE_USER" \
        || error_exit "Échec création user ${SONARQUBE_USER}"
else
    log "User ${SONARQUBE_USER} déjà existant, création ignorée"
fi

# ==== SQ Étape 3: Installation d'unzip si nécessaire ====
log "[SQ 3/9] Vérification de unzip"
if ! command -v unzip >/dev/null 2>&1; then
    sudo yum install -y unzip || error_exit "Échec installation unzip"
fi

# ==== SQ Étape 4: Téléchargement de SonarQube ====
log "[SQ 4/9] Téléchargement de SonarQube ${SONARQUBE_VERSION}"
mkdir -p "$SONARQUBE_TMP_DIR"
cd "$SONARQUBE_TMP_DIR" || error_exit "Impossible d'accéder à ${SONARQUBE_TMP_DIR}"

SONARQUBE_ZIP_FILE="sonarqube-${SONARQUBE_VERSION}.zip"
if [ -f "$SONARQUBE_HOME/bin/linux-x86-64/sonar.sh" ]; then
    log "SonarQube déjà installé dans ${SONARQUBE_HOME}, téléchargement ignoré"
else
    if [ ! -f "$SONARQUBE_ZIP_FILE" ]; then
        retry_download "$SONARQUBE_ZIP_URL" "$SONARQUBE_ZIP_FILE" \
            || error_exit "Échec du téléchargement de SonarQube"
    fi

    # ==== SQ Étape 5: Extraction et installation ====
    log "[SQ 5/9] Extraction de SonarQube"
    unzip -q -o "$SONARQUBE_ZIP_FILE" || error_exit "Échec de l'extraction de SonarQube"

    log "Copie vers ${SONARQUBE_HOME}"
    sudo cp -a "sonarqube-${SONARQUBE_VERSION}/." "$SONARQUBE_HOME/" \
        || error_exit "Échec de la copie vers ${SONARQUBE_HOME}"
    sudo chown -R "${SONARQUBE_USER}:${SONARQUBE_USER}" "$SONARQUBE_HOME"

    rm -f "$SONARQUBE_ZIP_FILE"
fi

# ==== SQ Étape 6: Service systemd ====
log "[SQ 6/9] Configuration du service systemd sonarqube"
sudo tee /etc/systemd/system/sonarqube.service > /dev/null <<EOF
[Unit]
Description=SonarQube service
After=network.target

[Service]
Type=forking
ExecStart=${SONARQUBE_HOME}/bin/linux-x86-64/sonar.sh start
ExecStop=${SONARQUBE_HOME}/bin/linux-x86-64/sonar.sh stop
User=${SONARQUBE_USER}
Group=${SONARQUBE_USER}
Restart=always
LimitNOFILE=65536
LimitNPROC=4096
TimeoutStartSec=300

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload

# ==== SQ Étape 7: Firewall port SonarQube ====
log "[SQ 7/9] Configuration firewall (port ${SONARQUBE_PORT})"
if ip link show "$IFACE" >/dev/null 2>&1; then
    sudo firewall-cmd --zone=public --add-port="${SONARQUBE_PORT}/tcp" --permanent || log "Firewall-cmd échoué pour le port SonarQube"
    sudo firewall-cmd --reload || log "Firewall reload échoué"
else
    log "Interface $IFACE non trouvée, configuration firewall SonarQube ignorée"
fi

# ==== SQ Étape 8: Activation du service ====
log "[SQ 8/9] Activation et démarrage de SonarQube"
sudo systemctl enable sonarqube || error_exit "Échec activation SonarQube"
sudo systemctl start sonarqube || error_exit "Échec démarrage SonarQube"

# ==== SQ Étape 9: Vérification ====
log "[SQ 9/9] Vérification du déploiement SonarQube"
log "Premier démarrage : peut prendre 1 à 2 minutes (Elasticsearch embarqué)..."

if wait_for_service "$SONARQUBE_PORT"; then
    log "✅ SonarQube répond correctement sur le port ${SONARQUBE_PORT}"
else
    log "❌ ERREUR: SonarQube ne répond pas sur le port ${SONARQUBE_PORT}"
    log "Affichage du statut sonarqube:"
    sudo systemctl status sonarqube --no-pager || true
    log "Affichage des logs SonarQube (dernières 30 lignes):"
    sudo tail -n 30 "${SONARQUBE_HOME}/logs/sonar.log" 2>/dev/null || true
    error_exit "SonarQube non fonctionnel"
fi

log "=== INSTALLATION SONARQUBE TERMINÉE ==="
log "🌐 URL: http://$(hostname -I | awk '{print $1}'):${SONARQUBE_PORT}"
log "🔑 Identifiants par défaut: admin / admin (changement demandé à la 1ère connexion)"
log "✅ Installation SonarQube réussie"

exit 0
