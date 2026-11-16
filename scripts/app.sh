
#!/usr/bin/env bash
set -euo pipefail

# RÉSULTATS-BF — Provisionnement applicatif

: "${DB_APP_PASSWORD:?Mot de passe PostgreSQL manquant}"
: "${APP_IP:?Adresse applicative manquante}"

: "${DB_HOST:?Adresse du primaire PostgreSQL manquante}"
INSTALL_DIR="/opt/resultats-bf"
ENV_FILE="/etc/resultats-bf/app.env"
SERVICE_FILE="/etc/systemd/system/resultats-bf.service"

echo "=== Provisionnement du serveur $(hostname) ==="

# 1. Installer Python et le pilote PostgreSQL.
apt-get update -qq

DEBIAN_FRONTEND=noninteractive apt-get install -y \
    python3 \
    python3-psycopg2

# 2. Installer le code applicatif.
install -d -m 0755 "$INSTALL_DIR"
install -m 0644 /vagrant/app/main.py "$INSTALL_DIR/main.py"

# 3. Enregistrer la configuration locale.
install -d -m 0700 /etc/resultats-bf

umask 077

cat > "$ENV_FILE" <<EOF
DB_HOST=${DB_HOST}
DB_APP_PASSWORD=${DB_APP_PASSWORD}
APP_IP=${APP_IP}
EOF

chown root:root "$ENV_FILE"
chmod 0600 "$ENV_FILE"

# 4. Définir le service systemd.
cat > "$SERVICE_FILE" <<'EOF'
[Unit]
Description=RESULTATS-BF API Python
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=www-data
EnvironmentFile=/etc/resultats-bf/app.env
ExecStart=/usr/bin/python3 /opt/resultats-bf/main.py
Restart=always
RestartSec=2
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF

# 5. Activer et démarrer l'application.
systemctl daemon-reload
systemctl enable resultats-bf.service
systemctl restart resultats-bf.service

echo "=== Serveur applicatif opérationnel ==="
