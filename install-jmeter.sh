#!/usr/bin/env bash
# Installation d'Apache JMeter 5.6.3 sur admin-agent (VM4) - à lancer en root
set -euo pipefail

JM_VER="5.6.3"
DEST="/opt"
URL1="https://dlcdn.apache.org/jmeter/binaries/apache-jmeter-${JM_VER}.tgz"
URL2="https://archive.apache.org/dist/jmeter/binaries/apache-jmeter-${JM_VER}.tgz"

echo "[1/5] Vérification de Java"
command -v java >/dev/null || { echo "Java absent : installer Corretto 21 d'abord"; exit 1; }
java -version 2>&1 | head -1

echo "[2/5] Téléchargement de JMeter ${JM_VER} (IPv4)"
cd /tmp
rm -f "apache-jmeter-${JM_VER}.tgz"
curl -4 -fSL -o "apache-jmeter-${JM_VER}.tgz" "$URL1" || curl -4 -fSL -o "apache-jmeter-${JM_VER}.tgz" "$URL2"
[ -s "apache-jmeter-${JM_VER}.tgz" ] || { echo "Téléchargement échoué : copier le .tgz à la main dans /tmp"; exit 1; }

echo "[3/5] Extraction dans ${DEST}"
tar -xzf "apache-jmeter-${JM_VER}.tgz" -C "$DEST"
ln -sfn "${DEST}/apache-jmeter-${JM_VER}" "${DEST}/jmeter"

echo "[4/5] Droits pour l'utilisateur adminagent"
[ -d "${DEST}/apache-jmeter-${JM_VER}" ] || { echo "Dossier JMeter introuvable"; exit 1; }
chown -R adminagent:adminagent "${DEST}/apache-jmeter-${JM_VER}"

echo "[5/5] PATH global"
echo 'export PATH=/opt/jmeter/bin:$PATH' > /etc/profile.d/jmeter.sh
/opt/jmeter/bin/jmeter --version | head -8
echo "JMeter installé : /opt/jmeter/bin/jmeter"
