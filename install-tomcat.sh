#!/bin/bash
# Installation de Tomcat 9 sur admin-agent (VM4) - port 8080
# Tomcat 9 (namespace javax.*) car le pom.xml utilise javax.servlet-api 4.0.1
# Usage: sudo bash install-tomcat.sh
set -uo pipefail

APP_USER="adminagent"          # utilisateur qui deploie via Jenkins (cp du WAR)
TOMCAT_HOME="/opt/tomcat"
TOMCAT_PORT="8080"

[ "$(id -u)" -eq 0 ] || { echo "Lancer avec sudo"; exit 1; }
id "$APP_USER" >/dev/null 2>&1 || { echo "ERREUR: utilisateur $APP_USER introuvable"; exit 1; }

echo "== 1/5 Java =="
JAVA_HOME_DIR=""
for d in /opt/jdk-21-corretto /opt/jdk-17-corretto; do
  [ -x "$d/bin/java" ] && { JAVA_HOME_DIR="$d"; break; }
done
if [ -z "$JAVA_HOME_DIR" ]; then
  JAVA_BIN=$(readlink -f "$(command -v java)" 2>/dev/null || true)
  [ -n "$JAVA_BIN" ] && JAVA_HOME_DIR=$(dirname "$(dirname "$JAVA_BIN")")
fi
[ -x "$JAVA_HOME_DIR/bin/java" ] || { echo "ERREUR: Java introuvable"; exit 1; }
echo "JAVA_HOME=$JAVA_HOME_DIR"
"$JAVA_HOME_DIR/bin/java" -version

echo "== 2/5 Telechargement de Tomcat 9 =="
cd /tmp
TGZ=""
for v in 9.0.98 9.0.97 9.0.96 9.0.100 9.0.99; do
  for url in \
    "https://repo1.maven.org/maven2/org/apache/tomcat/tomcat/${v}/tomcat-${v}.tar.gz" \
    "https://archive.apache.org/dist/tomcat/tomcat-9/v${v}/bin/apache-tomcat-${v}.tar.gz" \
    "https://dlcdn.apache.org/tomcat/tomcat-9/v${v}/bin/apache-tomcat-${v}.tar.gz"; do
    f="/tmp/tomcat-${v}.tar.gz"
    code=$(curl -4 -sS -L -m 300 --retry 2 -o "$f" -w "%{http_code}" "$url" 2>/dev/null || echo "000")
    if [ "$code" = "200" ] && tar -tzf "$f" >/dev/null 2>&1; then
      echo "OK  $code  $url"
      TGZ="$f"
      break 2
    fi
    echo "KO  $code  $url"
    rm -f "$f"
  done
done
[ -n "$TGZ" ] || { echo "ERREUR: aucune source n'a repondu. Voir les codes HTTP ci-dessus."; exit 1; }

echo "== 3/5 Installation =="
DIR=$(tar -tzf "$TGZ" | head -1 | cut -d/ -f1)
[ -n "$DIR" ] || { echo "ERREUR: dossier de l'archive introuvable"; exit 1; }
if systemctl is-active --quiet tomcat 2>/dev/null; then systemctl stop tomcat; fi
rm -rf "/opt/$DIR"
tar -xzf "$TGZ" -C /opt
ln -sfn "/opt/$DIR" "$TOMCAT_HOME"
chmod +x "$TOMCAT_HOME"/bin/*.sh
chown -R "$APP_USER:$APP_USER" "/opt/$DIR"
echo "Tomcat installe dans /opt/$DIR (lien: $TOMCAT_HOME)"

echo "== 4/5 Service systemd =="
cat > /etc/systemd/system/tomcat.service <<EOF
[Unit]
Description=Apache Tomcat 9
After=network.target

[Service]
Type=forking
User=${APP_USER}
Group=${APP_USER}
Environment=JAVA_HOME=${JAVA_HOME_DIR}
Environment=CATALINA_HOME=${TOMCAT_HOME}
Environment=CATALINA_BASE=${TOMCAT_HOME}
Environment=CATALINA_PID=${TOMCAT_HOME}/temp/tomcat.pid
ExecStart=${TOMCAT_HOME}/bin/startup.sh
ExecStop=${TOMCAT_HOME}/bin/shutdown.sh
TimeoutSec=120

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now tomcat

echo "== 5/5 Pare-feu et verification =="
if systemctl is-active --quiet firewalld; then
  firewall-cmd --add-port=${TOMCAT_PORT}/tcp --permanent
  firewall-cmd --reload
fi

code="000"
for i in $(seq 1 30); do
  code=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 3 "http://localhost:${TOMCAT_PORT}" 2>/dev/null || true)
  code=${code:-000}
  case "$code" in 000*) ;; *) echo "Tomcat repond sur le port ${TOMCAT_PORT} (HTTP $code)"; break ;; esac
  sleep 2
done
case "$code" in 000*) echo "Tomcat ne repond pas. Logs:"; tail -n 30 "${TOMCAT_HOME}/logs/catalina.out" 2>/dev/null; exit 1 ;; esac

echo
echo "Dossier de deploiement: ${TOMCAT_HOME}/webapps (proprietaire: ${APP_USER})"
echo "URL: http://10.21.244.154:${TOMCAT_PORT}"
