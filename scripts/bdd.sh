
#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# RESULTATS-BF — PostgreSQL 16 primaire
# Compatible avec bdd1 ou bdd2 comme primaire actif.
# ============================================================

DB_NAME="resultats_bf"
PG_VERSION="16"
CONFIG_DIR="/vagrant/config/postgresql"

PG_CONF="/etc/postgresql/${PG_VERSION}/main"
PG_SERVICE="postgresql@${PG_VERSION}-main"

# ------------------------------------------------------------
# 1. Vérifier les paramètres fournis par Vagrant
# ------------------------------------------------------------

: "${DB_APP_PASSWORD:?DB_APP_PASSWORD manquant}"
: "${DB_REPL_PASSWORD:?DB_REPL_PASSWORD manquant}"
: "${PRIMARY_IP:?PRIMARY_IP manquant}"
: "${REPLICA_IP:?REPLICA_IP manquant}"

case "$PRIMARY_IP" in
    192.168.56.31)
        EXPECTED_REPLICA_IP="192.168.56.32"
        SLOT_NAME="bdd2_slot"
        ;;
    192.168.56.32)
        EXPECTED_REPLICA_IP="192.168.56.31"
        SLOT_NAME="bdd1_slot"
        ;;
    *)
        echo "ERREUR : adresse du primaire inconnue."
        exit 1
        ;;
esac

if [[ "$REPLICA_IP" != "$EXPECTED_REPLICA_IP" ]]; then
    echo "ERREUR : adresse de réplication incohérente."
    exit 1
fi

# Vérifier que la configuration centrale désigne bien
# cette machine comme primaire.

DECLARED_PRIMARY="$(
    tr -d '[:space:]' < /vagrant/config/primary_db_ip
)"

if [[ "$DECLARED_PRIMARY" != "$PRIMARY_IP" ]]; then
    echo "ERREUR : PRIMARY_IP ne correspond pas au primaire déclaré."
    exit 1
fi

# Vérifier que cette machine possède réellement
# l'adresse IP annoncée.

if ! ip -4 -o addr show |
    awk -v expected="$PRIMARY_IP" '
        {
            split($4, address, "/")
            if (address[1] == expected) {
                found = 1
            }
        }
        END {
            exit !found
        }
    '; then

    echo "ERREUR : cette machine ne possède pas ${PRIMARY_IP}."
    exit 1
fi

echo "============================================"
echo " RESULTATS-BF — Configuration du primaire"
echo "============================================"
echo "Primaire : ${PRIMARY_IP}"
echo "Réplique : ${REPLICA_IP}"
echo "Slot     : ${SLOT_NAME}"

# ------------------------------------------------------------
# 2. Installer PostgreSQL 16 si nécessaire
# ------------------------------------------------------------

if ! dpkg-query -W -f='${Status}' postgresql-16 \
    2>/dev/null | grep -qx "install ok installed"; then

    apt-get update -qq

    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        postgresql-16 \
        postgresql-client-16
fi

if [[ ! -d "$PG_CONF" ]]; then
    echo "ERREUR : configuration PostgreSQL 16 introuvable."
    exit 1
fi

# ------------------------------------------------------------
# 3. Démarrer le cluster et contrôler son rôle réel
# ------------------------------------------------------------

systemctl enable --now "$PG_SERVICE"

PG_ROLE="$(
    runuser -u postgres -- psql \
        -X -At -v ON_ERROR_STOP=1 \
        -d postgres \
        -c "SELECT pg_is_in_recovery();"
)"

if [[ "$PG_ROLE" != "f" ]]; then
    echo "ERREUR CRITIQUE : ce serveur est encore une réplique."
    echo "Provisionnement du primaire interrompu."
    echo "Aucune promotion automatique ne sera effectuée."
    exit 1
fi

echo "Rôle PostgreSQL confirmé : primaire."

# ------------------------------------------------------------
# 4. Configurer PostgreSQL
# ------------------------------------------------------------

mkdir -p "${PG_CONF}/conf.d"

TARGET_CONF="${PG_CONF}/conf.d/99-resultats-bf.conf"
TEMP_CONF="$(mktemp)"

trap 'rm -f "$TEMP_CONF"' EXIT

cat > "$TEMP_CONF" <<EOF
# RESULTATS-BF — PostgreSQL primaire

listen_addresses = 'localhost,${PRIMARY_IP}'

wal_level = replica
max_wal_senders = 5
max_replication_slots = 5

wal_keep_size = '256MB'
max_slot_wal_keep_size = '1024MB'

hot_standby = on
EOF

CONFIG_CHANGED=0

if ! cmp -s "$TEMP_CONF" "$TARGET_CONF"; then

    install -m 0644 "$TEMP_CONF" "$TARGET_CONF"
    CONFIG_CHANGED=1

fi

# ------------------------------------------------------------
# 5. Autoriser les connexions privées
# ------------------------------------------------------------

HBA="${PG_CONF}/pg_hba.conf"
HBA_CHANGED=0

add_hba_rule() {
    local rule="$1"

    if ! grep -Fqx "$rule" "$HBA"; then
        printf '%s\n' "$rule" >> "$HBA"
        HBA_CHANGED=1
    fi
}

# Connexions des applications.
add_hba_rule \
    "host resultats_bf resultats_app 192.168.56.0/24 scram-sha-256"

# Connexion de réplication autorisée uniquement
# depuis l'adresse de l'autre serveur PostgreSQL.
add_hba_rule \
    "host replication resultats_replica ${REPLICA_IP}/32 scram-sha-256"

# ------------------------------------------------------------
# 6. Appliquer les modifications
# ------------------------------------------------------------

if [[ "$CONFIG_CHANGED" -eq 1 ]]; then

    echo "Configuration modifiée : redémarrage PostgreSQL."
    systemctl restart "$PG_SERVICE"

elif [[ "$HBA_CHANGED" -eq 1 ]]; then

    echo "Règles d'accès modifiées : rechargement PostgreSQL."
    systemctl reload "$PG_SERVICE"

fi

# Vérification après application de la configuration.

PG_ROLE="$(
    runuser -u postgres -- psql \
        -X -At -v ON_ERROR_STOP=1 \
        -d postgres \
        -c "SELECT pg_is_in_recovery();"
)"

if [[ "$PG_ROLE" != "f" ]]; then
    echo "ERREUR : PostgreSQL n'est plus primaire."
    exit 1
fi

# ------------------------------------------------------------
# 7. Créer les rôles PostgreSQL si nécessaire
# ------------------------------------------------------------

runuser -u postgres -- psql \
    -X -v ON_ERROR_STOP=1 \
    -v app_password="$DB_APP_PASSWORD" \
    -v repl_password="$DB_REPL_PASSWORD" \
    -d postgres <<'SQL'

SELECT format(
    'CREATE ROLE %I LOGIN PASSWORD %L',
    'resultats_app',
    :'app_password'
)
WHERE NOT EXISTS (
    SELECT 1
    FROM pg_roles
    WHERE rolname = 'resultats_app'
)
\gexec

SELECT format(
    'CREATE ROLE %I WITH REPLICATION LOGIN PASSWORD %L',
    'resultats_replica',
    :'repl_password'
)
WHERE NOT EXISTS (
    SELECT 1
    FROM pg_roles
    WHERE rolname = 'resultats_replica'
)
\gexec

SQL

# ------------------------------------------------------------
# 8. Vérifier les droits du compte de réplication
# ------------------------------------------------------------

REPL_ROLE_OK="$(
    runuser -u postgres -- psql \
        -X -At -v ON_ERROR_STOP=1 \
        -d postgres \
        -c "SELECT COUNT(*)
            FROM pg_roles
            WHERE rolname = 'resultats_replica'
            AND rolcanlogin
            AND rolreplication;"
)"

if [[ "$REPL_ROLE_OK" != "1" ]]; then
    echo "ERREUR : compte de réplication non opérationnel."
    exit 1
fi

# ------------------------------------------------------------
# 9. Créer la base si nécessaire
# ------------------------------------------------------------

runuser -u postgres -- psql \
    -X -v ON_ERROR_STOP=1 \
    -d postgres <<'SQL'

SELECT format(
    'CREATE DATABASE %I',
    'resultats_bf'
)
WHERE NOT EXISTS (
    SELECT 1
    FROM pg_database
    WHERE datname = 'resultats_bf'
)
\gexec

GRANT CONNECT ON DATABASE resultats_bf TO resultats_app;

SQL

# ------------------------------------------------------------
# 10. Initialiser les données de manière idempotente
# ------------------------------------------------------------

if [[ ! -f "${CONFIG_DIR}/init.sql" ]]; then
    echo "ERREUR : script SQL d'initialisation manquant."
    exit 1
fi

runuser -u postgres -- psql \
    -X -v ON_ERROR_STOP=1 \
    -d "$DB_NAME" \
    -f "${CONFIG_DIR}/init.sql"

# ------------------------------------------------------------
# 11. Vérifier le nombre de résultats
# ------------------------------------------------------------

NB_RESULTATS="$(
    runuser -u postgres -- psql \
        -X -At -v ON_ERROR_STOP=1 \
        -d "$DB_NAME" \
        -c "SELECT COUNT(*) FROM public.resultats;"
)"

echo "Nombre de candidats : ${NB_RESULTATS}"

if [[ ! "$NB_RESULTATS" =~ ^[0-9]+$ ]] ||
   (( NB_RESULTATS < 50000 )); then

    echo "ERREUR : moins de 50000 candidats disponibles."
    exit 1
fi

# ------------------------------------------------------------
# 12. Créer le slot de réplication si nécessaire
# ------------------------------------------------------------

runuser -u postgres -- psql \
    -X -v ON_ERROR_STOP=1 \
    -v slot_name="$SLOT_NAME" \
    -d postgres <<'SQL'

SELECT pg_create_physical_replication_slot(:'slot_name')
WHERE NOT EXISTS (
    SELECT 1
    FROM pg_replication_slots
    WHERE slot_name = :'slot_name'
);

SQL

# ------------------------------------------------------------
# 13. Vérifications finales
# ------------------------------------------------------------

if ! pg_isready -h "$PRIMARY_IP" -p 5432; then
    echo "ERREUR : primaire PostgreSQL inaccessible."
    exit 1
fi

SLOT_OK="$(
    runuser -u postgres -- psql \
        -X -At -v ON_ERROR_STOP=1 \
        -v slot_name="$SLOT_NAME" \
        -d postgres <<'SQL'
SELECT COUNT(*)
FROM pg_replication_slots
WHERE slot_name = :'slot_name'
  AND slot_type = 'physical';
SQL
)"

if [[ "$SLOT_OK" != "1" ]]; then
    echo "ERREUR : slot de réplication absent."
    exit 1
fi

echo "============================================"
echo " PostgreSQL primaire opérationnel"
echo " Primaire : ${PRIMARY_IP}"
echo " Réplique : ${REPLICA_IP}"
echo " Slot     : ${SLOT_NAME}"
echo " Candidats: ${NB_RESULTATS}"
echo "============================================"
