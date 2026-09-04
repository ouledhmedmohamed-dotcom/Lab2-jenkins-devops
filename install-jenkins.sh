#!/bin/bash
set -e

echo ">>> [1/8] Correction repos CentOS7 EOL"
sudo sed -i \
  -e 's/mirrorlist=/#mirrorlist=/g' \
  -e 's|#baseurl=http://mirror.centos.org|baseurl=http://vault.centos.org|g' \
  /etc/yum.repos.d/CentOS-*.repo

echo ">>> [2/8] Réseau"
sudo nmcli connection up enp0s3 || true

echo ">>> [3/8] Java 21 Temurin (build 21.0.12.1+1, identique à Jenkins-Server-v1)"
cd /opt
sudo curl -L -o jdk21.tar.gz \
  "https://api.adoptium.net/v3/binary/version/jdk-21.0.12+1/linux/x64/jdk/hotspot/normal/eclipse?project=jdk"
sudo tar -xzf jdk21.tar.gz
JDK_DIR=$(find /opt -maxdepth 1 -iname "jdk-21*" -type d | head -1)
sudo alternatives --install /usr/bin/java java "$JDK_DIR/bin/java" 1
sudo alternatives --set java "$JDK_DIR/bin/java"

echo ">>> [4/8] Repo + installation Jenkins"
sudo curl -o /etc/yum.repos.d/jenkins.repo https://pkg.jenkins.io/redhat-stable/jenkins.repo
sudo rpm --import https://pkg.jenkins.io/redhat-stable/jenkins.io-2023.key
sudo yum install -y jenkins
# NB: le package crée automatiquement l'utilisateur "jenkins" (confirmé User=jenkins sur la VM de référence)

echo ">>> [5/8] Override systemd (identique à Jenkins-Server-v1)"
sudo mkdir -p /etc/systemd/system/jenkins.service.d
sudo tee /etc/systemd/system/jenkins.service.d/override.conf > /dev/null <<'EOF'
[Service]
Environment="JENKINS_LISTEN_ADDRESS=0.0.0.0"
Environment="JAVA_OPTS=-Djava.net.preferIPv4Stack=true"
TimeoutStartSec=600
EOF
sudo systemctl daemon-reload

echo ">>> [6/8] Firewall (zone public, interface enp0s3, port 8080)"
sudo firewall-cmd --zone=public --add-port=8080/tcp --permanent
sudo firewall-cmd --zone=public --change-interface=enp0s3 --permanent
sudo firewall-cmd --reload

echo ">>> [7/8] Activation service"
sudo systemctl enable --now jenkins

echo ">>> [8/8] Vérification"
sleep 10
sudo systemctl status jenkins --no-pager
curl -I http://localhost:8080 || true
