#!/bin/bash
# Installation de SonarQube sur sonar-server (VM2) - port 9000
# Usage: sudo bash install-sonarqube.sh
# Essaie plusieurs sources de telechargement et utilise la premiere qui repond.
set -uo pipefail

JDK17="/opt/jdk-17-corretto"
JDK21="/opt/jdk-21-corretto"

[ "$(id -u)" -eq 0 ] || { echo "Lancer avec sudo"; exit 1; }

echo "== 1/6 Parametres noyau =="
cat > /etc/sysctl.d/99-sonarqube.conf <<EOF
vm.max_map_count=524288
fs.file-max=131072
EOF
sysctl --system >/dev/null

echo "== 2/6 unzip =="
if ! command -v unzip >/dev/null; then
  yum install -y unzip --disablerepo=base,extras,updates 2>/dev/null || yum install -y unzip
fi

echo "== 3/6 Telechargement de SonarQube =="
cd /tmp
ZIP=""
MAVEN="https://repo1.maven.org/maven2/org/sonarsource/sonarqube/sonar-application"
BIN="https://binaries.sonarsource.com/Distribution/sonarqube"
CANDIDATES=(
  "$MAVEN/9.9.6.92038/sonar-application-9.9.6.92038.zip"
  "$MAVEN/9.9.5.90363/sonar-application-9.9.5.90363.zip"
  "$MAVEN/10.7.0.96327/sonar-application-10.7.0.96327.zip"
  "$BIN/sonarqube-9.9.6.92038.zip"
  "$BIN/sonarqube-10.7.0.96327.zip"
)
# Surcharge possible: SONARQUBE_URL=https://... sudo -E bash install-sonarqube.sh
[ -n "${SONARQUBE_URL:-}" ] && CANDIDATES=("$SONARQUBE_URL" "${CANDIDATES[@]}")
for url in "${CANDIDATES[@]}"; do
  f="/tmp/$(basename "$url")"
  code=$(curl -4 -sS -L -m 600 --retry 3 -o "$f" -w "%{http_code}" "$url" 2>/dev/null || echo "000")
  if [ "$code" = "200" ] && unzip -tq "$f" >/dev/null 2>&1; then
    echo "OK  $code  $url"
    ZIP="$f"
    break
  fi
  echo "KO  $code  $url"
  rm -f "$f"
done
if [ -z "$ZIP" ]; then
  echo "ERREUR: aucune source n'a repondu. Voir les codes HTTP ci-dessus."
  exit 1
fi

DIR=$(unzip -Z1 "$ZIP" | head -1 | cut -d/ -f1)
[ -n "$DIR" ] || { echo "ERREUR: dossier du ZIP introuvable"; exit 1; }
echo "Dossier: $DIR"

# Java: SonarQube 25+ exige Java 21, les versions 9.9 / 10.x utilisent Java 17
MAJOR=$(echo "$DIR" | grep -oE '[0-9]+' | head -1)
if [ "${MAJOR:-0}" -ge 25 ]; then JDK_DIR="$JDK21"; else JDK_DIR="$JDK17"; fi

echo "== 4/6 Java =="
if [ ! -x "$JDK_DIR/bin/java" ] && [ "$JDK_DIR" = "$JDK17" ]; then
  curl -4 -fL --retry 5 -o /tmp/corretto17.tar.gz https://corretto.aws/downloads/latest/amazon-corretto-17-x64-linux-jdk.tar.gz
  mkdir -p "$JDK_DIR"
  tar -xzf /tmp/corretto17.tar.gz -C "$JDK_DIR" --strip-components=1
fi
[ -x "$JDK_DIR/bin/java" ] || { echo "ERREUR: Java introuvable dans $JDK_DIR"; exit 1; }
"$JDK_DIR/bin/java" -version

echo "== 5/6 Installation =="
id sonar &>/dev/null || useradd -r -m -d /opt/sonarqube -s /bin/bash sonar
[ -d "/opt/$DIR" ] || unzip -q "$ZIP" -d /opt
rm -rf /opt/sonarqube/*
cp -a "/opt/$DIR/." /opt/sonarqube/
chown -R sonar:sonar /opt/sonarqube "/opt/$DIR"

echo "== 6/6 Service systemd =="
cat > /etc/systemd/system/sonarqube.service <<EOF
[Unit]
Description=SonarQube
After=network.target

[Service]
Type=forking
User=sonar
Environment=JAVA_HOME=${JDK_DIR}
Environment=SONAR_JAVA_PATH=${JDK_DIR}/bin/java
LimitNOFILE=131072
LimitNPROC=8192
ExecStart=/opt/sonarqube/bin/linux-x86-64/sonar.sh start
ExecStop=/opt/sonarqube/bin/linux-x86-64/sonar.sh stop
TimeoutSec=300

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now sonarqube

if systemctl is-active --quiet firewalld; then
  firewall-cmd --add-port=9000/tcp --permanent
  firewall-cmd --reload
fi

echo "Attente du demarrage (max 3 min)..."
for i in $(seq 1 90); do
  code=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 3 http://localhost:9000 2>/dev/null || echo 000)
  [ "$code" != "000" ] && { echo "SonarQube repond sur le port 9000 (HTTP $code)"; break; }
  sleep 2
done
[ "$code" = "000" ] && { echo "SonarQube ne repond pas. Logs:"; tail -n 30 /opt/sonarqube/logs/sonar.log 2>/dev/null; exit 1; }

echo
echo "SonarQube demarre (1-2 min). Suivre avec : sudo tail -f /opt/sonarqube/logs/sonar.log"
echo "Attendre 'SonarQube is operational', puis ouvrir http://10.21.244.152:9000 (admin/admin)"
