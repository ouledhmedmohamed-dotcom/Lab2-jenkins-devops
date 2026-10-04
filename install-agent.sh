#!/bin/bash
# ============================================================
#  VM4 - Jenkins build agent "admin-agent" (CentOS 7)
#  Installe : Java 21 (Temurin), Git, Maven, SSH, JMeter (optionnel)
#  Crée l'utilisateur "adminagent" et le dossier de travail Jenkins
#  Usage : sudo bash install-agent.sh
# ============================================================
set -euo pipefail

# ==== Variables ====
IFACE="${IFACE:-enp0s3}"
AGENT_USER="${AGENT_USER:-adminagent}"
AGENT_HOME="/home/${AGENT_USER}"
AGENT_WORKDIR="${AGENT_HOME}/jenkins-agent"
JDK_RELEASE="${JDK_RELEASE:-jdk-21.0.12+1}"
JDK_API_URL="https://api.adoptium.net/v3/binary/version/${JDK_RELEASE}/linux/x64/jdk/hotspot/normal/eclipse?project=jdk"
MAVEN_VERSION="${MAVEN_VERSION:-3.9.6}"
MAVEN_URL="https://archive.apache.org/dist/maven/maven-3/${MAVEN_VERSION}/binaries/apache-maven-${MAVEN_VERSION}-bin.tar.gz"
INSTALL_JMETER="${INSTALL_JMETER:-yes}"
JMETER_VERSION="${JMETER_VERSION:-5.6.3}"
JMETER_URL="https://archive.apache.org/dist/jmeter/binaries/apache-jmeter-${JMETER_VERSION}.tgz"
LOG_FILE="/var/log/agent-install.log"
MAX_RETRIES=5
RETRY_DELAY=10

# ==== Fonctions ====
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }
error_exit() { log "ERREUR: $*"; exit 1; }

retry_download() {
    local url=$1 output=$2 retries=0
    while [ $retries -lt $MAX_RETRIES ]; do
        if curl -fL -4 -o "$output" "$url" --connect-timeout 30 --max-time 600; then
            return 0
        fi
        retries=$((retries + 1))
        log "Tentative $retries/$MAX_RETRIES échouée, nouvelle tentative dans ${RETRY_DELAY}s..."
        sleep $RETRY_DELAY
    done
    return 1
}

[ "$EUID" -eq 0 ] || { echo "Ce script doit être exécuté en root (sudo)"; exit 1; }
mkdir -p "$(dirname "$LOG_FILE")"
log "=== Début installation agent admin-agent ==="

# ==== 1/8 Dépôts CentOS 7 (EOL) ====
log "[1/8] Correction des dépôts CentOS7 EOL"
sed -i.bak \
    -e 's/mirrorlist=/#mirrorlist=/g' \
    -e 's|#baseurl=http://mirror.centos.org|baseurl=http://vault.centos.org|g' \
    /etc/yum.repos.d/CentOS-*.repo 2>/dev/null || log "Aucun repo CentOS trouvé"
yum clean all
yum makecache || log "Cache yum créé avec des warnings"

# ==== 2/8 Réseau ====
log "[2/8] Réseau (interface $IFACE)"
if command -v nmcli >/dev/null 2>&1; then
    nmcli connection up "$IFACE" 2>/dev/null || log "Interface $IFACE non activée via nmcli"
fi
ping -c 1 -W 5 8.8.8.8 >/dev/null 2>&1 || log "ATTENTION: connectivité limitée"
log "IP actuelle : $(hostname -I | awk '{print $1}')  (pense à la rendre STATIQUE)"

# ==== 3/8 Paquets de base ====
log "[3/8] Installation git, openssh-server, unzip, tar, curl"
yum install -y git openssh-server unzip tar curl || error_exit "Échec installation des paquets"

# ==== 4/8 Java 21 ====
log "[4/8] Java 21 Temurin (${JDK_RELEASE})"
cd /opt
JDK_DIR=$(find /opt -maxdepth 1 -type d \( -iname "jdk-21*" -o -iname "temurin-21*" \) 2>/dev/null | head -1)
if [ -z "$JDK_DIR" ]; then
    FETCH_URL=$(curl -4 -s -o /dev/null -w '%{redirect_url}' "$JDK_API_URL" --connect-timeout 30) \
        || error_exit "Échec récupération URL JDK"
    FILENAME=$(basename "$FETCH_URL")
    retry_download "$FETCH_URL" "$FILENAME" || error_exit "Échec téléchargement JDK"
    tar -xzf "$FILENAME" || error_exit "Échec extraction JDK"
    rm -f "$FILENAME"
    JDK_DIR=$(find /opt -maxdepth 1 -type d \( -iname "jdk-21*" -o -iname "temurin-21*" \) | head -1)
fi
[ -n "$JDK_DIR" ] || error_exit "JDK introuvable"
alternatives --install /usr/bin/java java "$JDK_DIR/bin/java" 1 || true
alternatives --set java "$JDK_DIR/bin/java"
cat > /etc/profile.d/java.sh <<EOF
export JAVA_HOME=${JDK_DIR}
export PATH=\$JAVA_HOME/bin:\$PATH
EOF
java -version

# ==== 5/8 Maven ====
log "[5/8] Maven ${MAVEN_VERSION}"
if [ ! -d "/opt/apache-maven-${MAVEN_VERSION}" ]; then
    retry_download "$MAVEN_URL" /tmp/maven.tar.gz || error_exit "Échec téléchargement Maven"
    tar -xzf /tmp/maven.tar.gz -C /opt && rm -f /tmp/maven.tar.gz
fi
ln -sfn "/opt/apache-maven-${MAVEN_VERSION}" /opt/maven
cat > /etc/profile.d/maven.sh <<'EOF'
export M2_HOME=/opt/maven
export PATH=$M2_HOME/bin:$PATH
EOF

# ==== 6/8 JMeter (optionnel) ====
if [ "$INSTALL_JMETER" = "yes" ]; then
    log "[6/8] JMeter ${JMETER_VERSION}"
    if [ ! -d "/opt/apache-jmeter-${JMETER_VERSION}" ]; then
        retry_download "$JMETER_URL" /tmp/jmeter.tgz || error_exit "Échec téléchargement JMeter"
        tar -xzf /tmp/jmeter.tgz -C /opt && rm -f /tmp/jmeter.tgz
    fi
    ln -sfn "/opt/apache-jmeter-${JMETER_VERSION}" /opt/jmeter
    cat > /etc/profile.d/jmeter.sh <<'EOF'
export PATH=/opt/jmeter/bin:$PATH
EOF
else
    log "[6/8] JMeter ignoré (INSTALL_JMETER=$INSTALL_JMETER)"
fi

# ==== 7/8 Utilisateur agent + SSH ====
log "[7/8] Utilisateur ${AGENT_USER} et dossier de travail"
id "$AGENT_USER" >/dev/null 2>&1 || useradd -m -s /bin/bash "$AGENT_USER"
mkdir -p "$AGENT_WORKDIR" "${AGENT_HOME}/.ssh"
chmod 700 "${AGENT_HOME}/.ssh"
touch "${AGENT_HOME}/.ssh/authorized_keys"
chmod 600 "${AGENT_HOME}/.ssh/authorized_keys"
chown -R "${AGENT_USER}:${AGENT_USER}" "$AGENT_HOME"

systemctl enable sshd
systemctl start sshd
if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
    firewall-cmd --permanent --add-service=ssh || true
    firewall-cmd --reload || true
fi

# ==== 8/8 Vérification ====
log "[8/8] Vérification"
bash -lc 'java -version 2>&1 | head -1; mvn -version 2>&1 | head -1; git --version'
[ "$INSTALL_JMETER" = "yes" ] && bash -lc 'jmeter --version 2>&1 | grep -i version | head -1' || true

IP=$(hostname -I | awk '{print $1}')
log "=== INSTALLATION AGENT TERMINÉE ==="
log "Node Jenkins : nom=admin-agent | label=admin-agent | host=${IP} | user=${AGENT_USER}"
log "Remote root directory : ${AGENT_WORKDIR}"
log "Étape suivante : définir le mot de passe (passwd ${AGENT_USER}) ou ajouter la clé publique de Jenkins dans ${AGENT_HOME}/.ssh/authorized_keys"
exit 0
