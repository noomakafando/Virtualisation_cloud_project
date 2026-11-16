#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# RESULTATS-BF — Supervision E2
# Prometheus + Blackbox Exporter sur lb1
# ============================================================

echo "============================================"
echo " RESULTATS-BF — Supervision E2"
echo "============================================"

if [[ "$EUID" -ne 0 ]]; then
    echo "ERREUR : exécution root nécessaire."
    exit 1
fi

if [[ "$(hostname -s)" != "lb1" ]]; then
    echo "ERREUR : ce script doit être exécuté sur lb1."
    exit 1
fi

SOURCE="/vagrant/config/monitoring/prometheus.yml"
DEST="/etc/prometheus/prometheus.yml"

if [[ ! -f "$SOURCE" ]]; then
    echo "ERREUR : configuration Prometheus absente."
    exit 1
fi

# ------------------------------------------------------------
# 1. Installer les paquets si nécessaire
# ------------------------------------------------------------

NEED_INSTALL=0

for package in prometheus prometheus-blackbox-exporter; do
    if ! dpkg-query -W -f='${Status}' "$package" \
        2>/dev/null | grep -qx "install ok installed"; then
        NEED_INSTALL=1
    fi
done

if [[ "$NEED_INSTALL" -eq 1 ]]; then
    echo "Installation des composants de supervision..."

    apt-get update -qq

    DEBIAN_FRONTEND=noninteractive \
        apt-get install -y --no-install-recommends \
        prometheus \
        prometheus-blackbox-exporter
fi

# ------------------------------------------------------------
# 2. Valider la configuration AVANT installation
# ------------------------------------------------------------

echo "Vérification de la configuration Prometheus..."

promtool check config "$SOURCE"

# ------------------------------------------------------------
# 3. Installer la configuration
# ------------------------------------------------------------

CONFIG_CHANGED=0

if ! cmp -s "$SOURCE" "$DEST"; then
    install -o root -g root -m 0644 "$SOURCE" "$DEST"
    CONFIG_CHANGED=1
fi

# ------------------------------------------------------------
# 4. Limiter mémoire, disque et exposition réseau
# ------------------------------------------------------------

# Les deux services écouteront uniquement sur localhost.
# Aucun port supplémentaire ne sera exposé par Vagrant.
#
# Prometheus :
# - stockage local
# - rétention de 12 heures
# - maximum 150 MB pour les blocs persistants
#
# Blackbox :
# - requêtes locales uniquement

PROM_DROPIN="/etc/systemd/system/prometheus.service.d"
BLACKBOX_DROPIN="/etc/systemd/system/prometheus-blackbox-exporter.service.d"

mkdir -p "$PROM_DROPIN" "$BLACKBOX_DROPIN"

PROM_OVERRIDE="$PROM_DROPIN/override.conf"
BLACKBOX_OVERRIDE="$BLACKBOX_DROPIN/override.conf"

PROM_TEMP="$(mktemp)"
BLACKBOX_TEMP="$(mktemp)"

trap 'rm -f "$PROM_TEMP" "$BLACKBOX_TEMP"' EXIT

cat > "$PROM_TEMP" <<'EOF'
[Service]
ExecStart=
ExecStart=/usr/bin/prometheus --config.file=/etc/prometheus/prometheus.yml --storage.tsdb.path=/var/lib/prometheus/metrics2 --storage.tsdb.retention.time=12h --storage.tsdb.retention.size=150MB --web.listen-address=127.0.0.1:9090
MemoryMax=180M
EOF

cat > "$BLACKBOX_TEMP" <<'EOF'
[Service]
ExecStart=
ExecStart=/usr/bin/prometheus-blackbox-exporter --config.file=/etc/prometheus/blackbox.yml --web.listen-address=127.0.0.1:9115
MemoryMax=80M
EOF

PROM_SERVICE_CHANGED=0
BLACKBOX_SERVICE_CHANGED=0

if ! cmp -s "$PROM_TEMP" "$PROM_OVERRIDE"; then
    install -o root -g root -m 0644 \
        "$PROM_TEMP" "$PROM_OVERRIDE"
    PROM_SERVICE_CHANGED=1
fi

if ! cmp -s "$BLACKBOX_TEMP" "$BLACKBOX_OVERRIDE"; then
    install -o root -g root -m 0644 \
        "$BLACKBOX_TEMP" "$BLACKBOX_OVERRIDE"
    BLACKBOX_SERVICE_CHANGED=1
fi

# ------------------------------------------------------------
# 5. Appliquer les changements systemd
# ------------------------------------------------------------

if [[ "$PROM_SERVICE_CHANGED" -eq 1 ||
      "$BLACKBOX_SERVICE_CHANGED" -eq 1 ]]; then

    systemctl daemon-reload
fi

systemctl enable prometheus prometheus-blackbox-exporter

if [[ "$BLACKBOX_SERVICE_CHANGED" -eq 1 ]]; then
    systemctl restart prometheus-blackbox-exporter
else
    systemctl start prometheus-blackbox-exporter
fi

if [[ "$PROM_SERVICE_CHANGED" -eq 1 ]]; then
    systemctl restart prometheus
elif [[ "$CONFIG_CHANGED" -eq 1 ]]; then
    systemctl reload prometheus
else
    systemctl start prometheus
fi

# ------------------------------------------------------------
# 6. Vérifier la disponibilité des services
# ------------------------------------------------------------

systemctl is-active --quiet prometheus
systemctl is-active --quiet prometheus-blackbox-exporter

PROM_OK=0
BLACKBOX_OK=0

for attempt in {1..20}; do

    if curl -fsS --max-time 3 \
        http://127.0.0.1:9090/-/ready \
        >/dev/null 2>&1; then
        PROM_OK=1
    fi

    if curl -fsS --max-time 3 \
        http://127.0.0.1:9115/metrics \
        >/dev/null 2>&1; then
        BLACKBOX_OK=1
    fi

    if [[ "$PROM_OK" -eq 1 &&
          "$BLACKBOX_OK" -eq 1 ]]; then
        break
    fi

    sleep 1
done

if [[ "$PROM_OK" -ne 1 ||
      "$BLACKBOX_OK" -ne 1 ]]; then

    echo "ERREUR : supervision indisponible."
    exit 1
fi

# ------------------------------------------------------------
# 7. Première sonde HTTP
# ------------------------------------------------------------

PROBE_RESULT="$(
    curl -fsS --max-time 5 \
    'http://127.0.0.1:9115/probe?module=http_2xx&target=http://127.0.0.1/sante' |
    awk '$1 == "probe_success" {print $2}'
)"

if [[ "$PROBE_RESULT" != "1" ]]; then
    echo "ERREUR : sonde HAProxy en échec."
    exit 1
fi

echo "============================================"
echo " Supervision E2 opérationnelle"
echo " Prometheus : 127.0.0.1:9090"
echo " Blackbox   : 127.0.0.1:9115"
echo " Sonde HTTP : OK"
echo "============================================"
