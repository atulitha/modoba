#!/usr/bin/env bash
#
# modoboa-auto-install.sh
# Debian 13 - Fully automated Modoboa installer with default passwords
#
set -euo pipefail
IFS=$'\n\t'

###############################
# DEFAULT CONFIGURATION HERE
###############################

DOMAIN="qbits4dev"
MAIL_HOST="mail.qbits4dev.com"

ADMIN_USER="admin"
ADMIN_EMAIL="admin@qbits4dev.com"
ADMIN_PASSWORD="Admin123!"

DB_NAME="modoboa"
DB_USER="modouser"
DB_PASS="DBpass123!"

LE_EMAIL="admin@qbits4dev.com"

###############################
echo "=== Modoboa Automated Installer (Debian 13) ==="
echo "Using default passwords (NO PROMPTS)"
echo

###############################
# System Checks
###############################

echo "[+] Checking mail ports..."
if ss -ltnp | egrep -q ':(25|80|443|587|993)'; then
  echo "[-] ERROR: One or more required ports (25,80,443,587,993) are already in use."
  ss -ltnp | egrep ':(25|80|443|587|993)' || true
  exit 1
fi

echo "[+] Checking /tmp for noexec..."
if mount | grep -q ' /tmp .*noexec'; then
  echo "[-] ERROR: /tmp is mounted noexec. Modoboa installer will fail."
  exit 1
fi

###############################
# Install prerequisites
###############################

echo "[+] Installing prerequisites..."
export DEBIAN_FRONTEND=noninteractive
apt update
apt install -y git curl wget swaks ufw ca-certificates \
  python3 python3-venv python3-pip python3-setuptools \
  python3-packaging python3-wheel dialog \
  build-essential mariadb-server gnupg lsb-release apt-transport-https


###############################
# Setup MariaDB
###############################

echo "[+] Configuring MariaDB..."
systemctl enable --now mariadb

echo "[+] Creating Modoboa database + user..."
mysql -u root <<SQL
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
SQL

###############################
# Firewall
###############################

echo "[+] Configuring firewall (UFW)..."
ufw allow OpenSSH
ufw allow 25/tcp
ufw allow 587/tcp
ufw allow 465/tcp
ufw allow 993/tcp
ufw allow 143/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable

###############################
# Clone Modoboa Installer
###############################

echo "[+] Cloning modoboa-installer..."
cd /opt
if [[ -d /opt/modoboa-installer ]]; then
  mv /opt/modoboa-installer /opt/modoboa-installer.bak.$(date +%s)
fi
git clone https://github.com/modoboa/modoboa-installer.git
cd modoboa-installer

###############################
# Create installer.cfg
###############################

echo "[+] Writing installer.cfg..."

cat > installer.cfg <<EOF
[general]
interactive = false
domain = ${DOMAIN}
admin = ${ADMIN_USER}@${DOMAIN}
admin_password = ${ADMIN_PASSWORD}
install_web = true
create_admin = true

[database]
engine = mysql
install = false
host = 127.0.0.1
name = ${DB_NAME}
user = ${DB_USER}
password = ${DB_PASS}
port = 3306

[certificate]
generate = true
type = letsencrypt

[letsencrypt]
email = ${LE_EMAIL}

[mail]
hostname = ${MAIL_HOST}
EOF

chmod 600 installer.cfg

###############################
# Validate config
###############################

echo "[+] Validating installer.cfg..."
./run.py --stop-after-configfile-check --config installer.cfg

###############################
# Run installer
###############################

echo "[+] Running Modoboa installer (this may take 10–40 minutes)..."
sudo ./run.py --config installer.cfg 2>&1 | tee /tmp/modoboa-install-$(date +%F-%H%M).log

###############################
# Post-Install Checks
###############################

echo "[+] Checking service status..."
SERVICES=(nginx postfix dovecot mariadb rspamd amavis opendkim certbot clamav-freshclam)
for s in "${SERVICES[@]}"; do
  systemctl list-unit-files | grep -q "^${s}." && systemctl status $s --no-pager || echo "Service $s not installed or named differently"
done

echo "[+] Showing mail ports..."
ss -ltnp | egrep ':25|:80|:443|:587|:993' || true

echo "[+] Tail of mail log:"
tail -n 50 /var/log/mail.log || true

###############################
# Final Output
###############################

cat <<EOF

=================================================
  🎉 Modoboa Installation Finished!
=================================================

Access Web UI:
  https://${MAIL_HOST}/

Login credentials:
  Username: ${ADMIN_USER}@${DOMAIN}
  Password: ${ADMIN_PASSWORD}

DNS Required:
  A: ${MAIL_HOST} → YOUR_PUBLIC_IP
  MX: ${DOMAIN} → ${MAIL_HOST}
  SPF: "v=spf1 mx a ip4:YOUR_PUBLIC_IP -all"
  DKIM: Add the keys from Modoboa Admin UI
  DMARC: "v=DMARC1; p=quarantine"

PTR (reverse DNS):
  YOUR_PUBLIC_IP → ${MAIL_HOST}

Installer log saved to:
  /tmp/modoboa-install-*.log

=================================================
EOF

exit 0
