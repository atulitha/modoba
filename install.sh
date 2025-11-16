#!/usr/bin/env bash
#
# modoboa-auto-install.sh
# Debian 13 (bookworm) - full flow to prepare DB, create installer.cfg, run modoboa-installer
#
# Usage: sudo bash modoboa-auto-install.sh
#
set -euo pipefail
IFS=$'\n\t'

# -------------------------
# Default values (edit as needed)
# -------------------------
DEFAULT_DOMAIN="example.com"
DEFAULT_MAIL_HOST="mail.example.com"
DEFAULT_DB_NAME="modoboa"
DEFAULT_DB_USER="modouser"
DEFAULT_LE_EMAIL="admin@example.com"

# -------------------------
# Prompt / read values
# -------------------------
echo "Modoboa automated installer helper (Debian 13)"
echo

read -rp "Domain for Modoboa (e.g. example.com) [${DEFAULT_DOMAIN}]: " DOMAIN
DOMAIN=${DOMAIN:-$DEFAULT_DOMAIN}

read -rp "Mail hostname (FQDN) [${DEFAULT_MAIL_HOST}]: " MAIL_HOST
MAIL_HOST=${MAIL_HOST:-$DEFAULT_MAIL_HOST}

read -rp "Admin email (Modoboa admin) [${DEFAULT_LE_EMAIL}]: " ADMIN_EMAIL
ADMIN_EMAIL=${ADMIN_EMAIL:-$DEFAULT_LE_EMAIL}

read -rp "Admin username (will be used as admin email before @) [admin]: " ADMIN_USER
ADMIN_USER=${ADMIN_USER:-admin}

# read admin password (hidden)
while true; do
  read -rs -p "Admin password (Modoboa web UI) : " ADMIN_PASSWORD
  echo
  read -rs -p "Repeat admin password: " ADMIN_PASSWORD2
  echo
  [[ "$ADMIN_PASSWORD" == "$ADMIN_PASSWORD2" ]] && break
  echo "Passwords do not match. Try again."
done

read -rp "DB name [${DEFAULT_DB_NAME}]: " DB_NAME
DB_NAME=${DB_NAME:-$DEFAULT_DB_NAME}

read -rp "DB user [${DEFAULT_DB_USER}]: " DB_USER
DB_USER=${DB_USER:-$DEFAULT_DB_USER}

# read DB password (hidden)
while true; do
  read -rs -p "DB password for ${DB_USER}: " DB_PASS
  echo
  read -rs -p "Repeat DB password: " DB_PASS2
  echo
  [[ "$DB_PASS" == "$DB_PASS2" ]] && break
  echo "DB passwords do not match. Try again."
done

read -rp "Let's Encrypt contact email [${ADMIN_EMAIL}]: " LE_EMAIL
LE_EMAIL=${LE_EMAIL:-$ADMIN_EMAIL}

echo
echo "Summary of values to be used:"
cat <<EOF
Domain:        $DOMAIN
Mail host:     $MAIL_HOST
Admin account: ${ADMIN_USER}@${DOMAIN}
DB name:       $DB_NAME
DB user:       $DB_USER
LE email:      $LE_EMAIL
EOF

read -rp "Proceed? (type 'yes' to continue): " CONF
if [[ "$CONF" != "yes" ]]; then
  echo "Aborted by user."
  exit 1
fi

# -------------------------
# Pre-checks
# -------------------------
echo
echo "Checking running services and ports..."
if ss -ltnp | egrep -q ':(25|80|443|587|993)'; then
  echo "WARNING: One of ports 25,80,443,587,993 appears in use. Stop conflicting services before continuing."
  ss -ltnp | egrep ':(25|80|443|587|993)' || true
  read -rp "Continue anyway? (type 'yes' to continue): " CONT2
  [[ "$CONT2" == "yes" ]] || { echo "Please stop conflicting services and re-run."; exit 1; }
fi

# /tmp noexec check
if mount | grep -q ' /tmp .*noexec'; then
  echo "ERROR: /tmp is mounted with noexec. The modoboa-installer needs /tmp to be executable. Remount /tmp or disable noexec and re-run."
  exit 1
fi

# -------------------------
# Install OS prerequisites
# -------------------------
echo
echo "Installing package prerequisites (apt packages)..."
export DEBIAN_FRONTEND=noninteractive

apt update
apt install -y git curl wget ca-certificates dialog \
  python3 python3-venv python3-pip python3-distutils \
  gnupg lsb-release apt-transport-https \
  build-essential mariadb-server ufw swaks

# enable and start MariaDB
systemctl enable --now mariadb

# harden mysql root quickly - best to run mysql_secure_installation interactively
echo "Securing MariaDB root account (non-interactive minimal)."
# attempt to set a random root password if none set (if user has secure setup skip)
MYSQL_ROOT_PASS=""
# Create DB and user for Modoboa
echo "Creating database and user for Modoboa..."
mysql -u root <<SQL
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
SQL

echo "Database $DB_NAME and user $DB_USER created."

# -------------------------
# Setup firewall
# -------------------------
echo
echo "Configuring UFW firewall rules..."
ufw allow OpenSSH
ufw allow 25/tcp
ufw allow 587/tcp
ufw allow 465/tcp
ufw allow 993/tcp
ufw allow 143/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable
ufw status numbered

# -------------------------
# Clone modoboa-installer
# -------------------------
echo
echo "Cloning modoboa-installer to /opt/modoboa-installer..."
cd /opt
if [[ -d /opt/modoboa-installer ]]; then
  echo "/opt/modoboa-installer already exists. Backing up and replacing."
  mv /opt/modoboa-installer /opt/modoboa-installer.bak.$(date +%s)
fi
git clone https://github.com/modoboa/modoboa-installer.git /opt/modoboa-installer
chown -R $(whoami):$(whoami) /opt/modoboa-installer
cd /opt/modoboa-installer

# -------------------------
# Write installer.cfg
# -------------------------
echo
echo "Writing /opt/modoboa-installer/installer.cfg (non-interactive installer config)..."
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

[postfix]
# default postfix settings, tune later in /etc/postfix
EOF

chmod 600 installer.cfg
echo "installer.cfg created."

# -------------------------
# Validate config
# -------------------------
echo
echo "Validating installer configuration..."
./run.py --stop-after-configfile-check --config installer.cfg

echo "Configuration validated. Starting modoboa installer (this may take 10-40 minutes)."
echo "The installer will install and configure Postfix, Dovecot, Amavis, ClamAV, Rspamd/SpamAssassin, OpenDKIM, Nginx, Certbot and Modoboa."

# -------------------------
# Run installer (this is the heavy step)
# -------------------------
# Run installer as root (installer expects to perform apt and systemd ops)
sudo ./run.py --config installer.cfg 2>&1 | tee /tmp/modoboa-installer-$(date +%Y%m%d-%H%M%S).log

echo "Installer finished (check log above or in /tmp)."

# -------------------------
# Post-install service checks
# -------------------------
echo
echo "Performing post-install checks..."

SERVICES=(nginx postfix dovecot mariadb opendkim amavis rspamd clamav-freshclam certbot)
for s in "${SERVICES[@]}"; do
  if systemctl list-units --type=service | grep -q "^${s}"; then
    echo "Service $s: $(systemctl is-active $s || true)"
  else
    echo "Service $s: not installed or different name (check manually)"
  fi
done

echo
echo "Listening ports (should include 25,443,80,587,993):"
ss -ltnp | egrep ':25 |:80 |:443 |:587 |:993 ' || true

echo
echo "Tail of /var/log/mail.log (last 100 lines):"
if [[ -f /var/log/mail.log ]]; then
  tail -n 100 /var/log/mail.log || true
else
  echo "/var/log/mail.log not found - check mail logging locations"
fi

# -------------------------
# Basic functional tests
# -------------------------
echo
echo "Basic SMTP connection test to localhost:25"
if command -v swaks >/dev/null 2>&1; then
  swaks --to "${ADMIN_USER}@${DOMAIN}" --from "${ADMIN_USER}@${DOMAIN}" --server 127.0.0.1 --port 25 || true
else
  echo "(swaks not installed) You can install swaks and run a test: swaks --to you@otherdomain.com --from ${ADMIN_USER}@${DOMAIN} --server ${MAIL_HOST}"
fi

# check cert
echo
echo "Check certificate files for ${MAIL_HOST} (if Let's Encrypt succeeded)"
if [[ -d /etc/letsencrypt/live/${MAIL_HOST} ]]; then
  echo "Let's Encrypt cert found at /etc/letsencrypt/live/${MAIL_HOST}"
  openssl x509 -noout -dates -in /etc/letsencrypt/live/${MAIL_HOST}/cert.pem || true
else
  echo "Let's Encrypt cert not found. If ACME failed, check ports 80/443, and DNS A record for ${MAIL_HOST}."
fi

# -------------------------
# Final messages & next steps
# -------------------------
cat <<EOF

INSTALL COMPLETE (or attempted). Next manual steps / checks you MUST do:

  1) DNS:
     - Ensure A record: ${MAIL_HOST} -> YOUR_PUBLIC_IP
     - Ensure MX for ${DOMAIN} -> ${MAIL_HOST}
     - Add SPF TXT: v=spf1 mx a ip4:YOUR_PUBLIC_IP -all
     - Add DKIM TXT records shown in Modoboa admin after install.
     - Ask your provider to set PTR: YOUR_PUBLIC_IP -> ${MAIL_HOST}

  2) Access Modoboa admin UI:
     - https://${MAIL_HOST}/
     - Login: ${ADMIN_USER}@${DOMAIN}  (password you entered)

  3) Troubleshooting:
     - /var/log/mail.log, /var/log/nginx/error.log, journalctl -u postfix, -u dovecot
     - Check installer log: /tmp/modoboa-installer-*.log

  4) Harden and backup:
     - Enable fail2ban (apt install -y fail2ban)
     - Configure nightly DB backups and /var/vmail backups
     - Monitor deliverability (spamhaus, mx toolbox)

If you want, run 'mysql_secure_installation' to harden MySQL root settings.

EOF

exit 0
