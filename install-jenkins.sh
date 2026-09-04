#!/bin/bash
set -e

# --- Réseau ---
ensure_network() {
    local iface
    iface=$(nmcli -t -f DEVICE,TYPE connection show | grep ethernet | cut -d: -f1)
    if [ -z "$iface" ]; then echo "Aucune interface trouvée."; exit 1; fi
    sudo nmcli connection up "$iface"
    sudo nmcli connection modify "$iface" connection.autoconnect yes
    sleep 2
    if ! ping -c1 -W2 8.8.8.8 &>/dev/null; then
        echo "Échec réseau."
        exit 1
    fi
    echo "Réseau OK."
}
ensure_network

# --- Repos EOL ---
fix_repos_eol() {
    if ! curl -s --head http://mirrorlist.centos.org &>/dev/null; then
        sudo sed -i 's/mirrorlist=/#mirrorlist=/g' /etc/yum.repos.d/CentOS-*.repo
        sudo sed -i 's|#baseurl=http://mirror.centos.org|baseurl=http://vault.centos.org|g' /etc/yum.repos.d/CentOS-*.repo
        sudo yum clean all
    fi
    echo "Dépôts OK."
}
fix_repos_eol

# --- Java 21 (Temurin, via Adoptium) ---
echo "Installation Java 21 (Temurin)"
JAVA_URL=$(curl -s "https://api.adoptium.net/v3/assets/latest/21/hotspot?architecture=x64&image_type=jdk&os=linux&vendor=eclipse" | grep -o '"link":"[^"]*"' | head -1 | cut -d'"' -f4)
cd /tmp
sudo curl -L -o java21.tar.gz "$JAVA_URL"
sudo mkdir -p /opt/java21
sudo tar -xzf java21.tar.gz -C /opt/java21 --strip-components=1
sudo alternatives --install /usr/bin/java java /opt/java21/bin/java 1
sudo alternatives --set java /opt/java21/bin/java
echo "Java 21 installé : $(java -version 2>&1 | head -1)"

# --- Jenkins ---
echo "Installation Jenkins"
sudo curl -L -o /etc/yum.repos.d/jenkins.repo https://pkg.jenkins.io/redhat-stable/jenkins.repo
sudo rpm --import https://pkg.jenkins.io/redhat-stable/jenkins.io-2023.key
sudo yum install -y jenkins

sudo systemctl daemon-reload
sudo systemctl enable jenkins
sudo systemctl start jenkins

# --- Firewall ---
sudo firewall-cmd --permanent --add-port=8080/tcp
sudo firewall-cmd --reload

echo "Terminé ! Jenkins status:"
sudo systemctl status jenkins --no-pager

echo "Mot de passe admin initial :"
sudo cat /var/lib/jenkins/secrets/initialAdminPassword
