
#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# RESULTATS-BF — Réplique PostgreSQL 16
#
# Compatible avec :
#   bdd1 primaire -> bdd2 réplique
#   bdd2 primaire -> bdd1 réplique
#
# Sécurité :
#   - Ne jamais promouvoir automatiquement une base.
#   - Ne jamais écraser un cluster primaire existant.
#   - Initialiser une nouvelle réplique uniquement sur
#     une VM où PostgreSQL n'était pas encore installé.
#   - Préserver une réplique déjà initialisée.
# ============================================================

PG_VERSION="16"
PG_SERVICE="postgresql@${PG_VERSION}-main"
PG_CONF="/etc/postgresql/${PG_VERSION}/main"
PG_DATA="/var/lib/postgresql/${PG_VERSION}/main"

STAGING="${PG_DATA}.resultats-stage"
BACKUP="${PG_DATA}.original"
PASSFILE="/var/lib/postgresql/.pgpass"

REPLICA_USER="resultats_replica"
DB_NAME="resultats_bf"

# ------------------------------------------------------------
# 1. Paramètres transmis par Vagrant
# ------------------------------------------------------------

: "${DB_REPL_PASSWORD:?DB_REPL_PASSWORD manquant}"
: "${PRIMARY_IP:?PRIMARY_IP manquant}"
: "${REPLICA_IP:?REPLICA_IP manquant}"
: "${REPLICA_NAME:?REPLICA_NAME manquant}"
: "${SLOT_NAME:?SLOT_NAME manquant}"

case "$REPLICA_NAME" in
    bdd1)
        EXPECTED_REPLICA_IP="192.168.56.31"
        EXPECTED_PRIMARY_IP="192.168.56.32"
        EXPECTED_SLOT="bdd1_slot"
        ;;
    bdd2)
        EXPECTED_REPLICA_IP="192.168.56.32"
        EXPECTED_PRIMARY_IP="192.168.56.31"
        EXPECTED_SLOT="bdd2_slot"
        ;;
    *)
        echo "ERREUR : nom de réplique inconnu."
        exit 1
        ;;
esac

if [[ "$REPLICA_IP" != "$EXPECTED_REPLICA_IP" ||
      "$PRIMARY_IP" != "$EXPECTED_PRIMARY_IP" ||
      "$SLOT_NAME" != "$EXPECTED_SLOT" ]]; then
    echo "ERREUR : paramètres PostgreSQL incohérents."
    exit 1
fi

if [[ "$(hostname -s)" != "$REPLICA_NAME" ]]; then
    echo "ERREUR : nom d'hôte inattendu."
    exit 1
fi

DECLARED_PRIMARY="$(
    tr -d '[:space:]' < /vagrant/config/primary_db_ip
)"

if [[ "$DECLARED_PRIMARY" != "$PRIMARY_IP" ]]; then
    echo "ERREUR : le primaire déclaré a changé."
    exit 1
fi

if ! ip -4 -o addr show |
     awk '{print $4}' |
     cut -d/ -f1 |
     grep -Fxq "$REPLICA_IP"; then
    echo "ERREUR : adresse IP locale incorrecte."
    exit 1
fi

echo "============================================"
echo " RESULTATS-BF — Réplication PostgreSQL"
echo "============================================"
echo "Primaire : ${PRIMARY_IP}"
echo "Réplique : ${REPLICA_NAME} (${REPLICA_IP})"
echo "Slot     : ${SLOT_NAME}"

# ------------------------------------------------------------
# 2. Détecter une installation existante
# ------------------------------------------------------------

PG_ALREADY_INSTALLED=0

if dpkg-query -W -f='${Status}' postgresql-16 \
    2>/dev/null | grep -qx "install ok installed"; then
    PG_ALREADY_INSTALLED=1
fi

# Une machine PostgreSQL déjà installée mais non
# initialisée comme réplique exige une intervention.
#
# Cela protège notamment l'ancien primaire bdd1.

if [[ "$PG_ALREADY_INSTALLED" -eq 1 &&
      ! -f "${PG_DATA}/standby.signal" ]]; then
    echo "ERREUR DE SECURITE : cluster existant non réplique."
    echo "Aucune donnée ne sera modifiée."
    echo "Utiliser une VM neuve pour reconstruire la réplique."
    exit 1
fi

# ------------------------------------------------------------
# 3. Installer PostgreSQL sur une VM neuve
# ------------------------------------------------------------

if [[ "$PG_ALREADY_INSTALLED" -eq 0 ]]; then

    echo "Installation de PostgreSQL 16..."

    apt-get update -qq

    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        postgresql-16 \
        postgresql-client-16

fi

if [[ ! -d "$PG_CONF" ||
      ! -d "$PG_DATA" ]]; then
    echo "ERREUR : cluster PostgreSQL introuvable."
    exit 1
fi

# ------------------------------------------------------------
# 4. Configurer l'adresse réseau de la réplique
# ------------------------------------------------------------

mkdir -p "${PG_CONF}/conf.d"

TARGET_CONF="${PG_CONF}/conf.d/99-resultats-bf.conf"
TEMP_CONF="$(mktemp)"

trap 'rm -f "$TEMP_CONF"' EXIT

cat > "$TEMP_CONF" <<EOF
# RESULTATS-BF — PostgreSQL réplique

listen_addresses = 'localhost,${REPLICA_IP}'
hot_standby = on

wal_level = replica
max_wal_senders = 5
max_replication_slots = 5

wal_keep_size = '256MB'
max_slot_wal_keep_size = '1024MB'
EOF

CONFIG_CHANGED=0

if ! cmp -s "$TEMP_CONF" "$TARGET_CONF"; then
    install -m 0644 "$TEMP_CONF" "$TARGET_CONF"
    CONFIG_CHANGED=1
fi

# ------------------------------------------------------------
# 5. Autoriser les connexions applicatives privées
# ------------------------------------------------------------

HBA="${PG_CONF}/pg_hba.conf"
HBA_CHANGED=0

APP_RULE="host resultats_bf resultats_app 192.168.56.0/24 scram-sha-256"

if ! grep -Fqx "$APP_RULE" "$HBA"; then
    printf '%s\n' "$APP_RULE" >> "$HBA"
    HBA_CHANGED=1
fi

# ------------------------------------------------------------
# 6. Configurer le mot de passe de réplication
# ------------------------------------------------------------

umask 077

printf '%s:%s:%s:%s:%s\n' \
    "$PRIMARY_IP" \
    "5432" \
    "replication" \
    "$REPLICA_USER" \
    "$DB_REPL_PASSWORD" > "$PASSFILE"

chown postgres:postgres "$PASSFILE"
chmod 0600 "$PASSFILE"

# ------------------------------------------------------------
# 7. Réplique déjà initialisée : préserver les données
# ------------------------------------------------------------

if [[ "$PG_ALREADY_INSTALLED" -eq 1 ]]; then

    echo "Réplique existante détectée."

    # Vérifier qu'elle pointe vers le bon primaire.

    if ! grep -Eq \
        "host=${PRIMARY_IP}([[:space:]]|')" \
        "${PG_DATA}/postgresql.auto.conf"; then

        echo "ERREUR : primaire configuré différent."
        echo "Reconstruction contrôlée nécessaire."
        exit 1
    fi

    if ! grep -Fq \
        "primary_slot_name = '${SLOT_NAME}'" \
        "${PG_DATA}/postgresql.auto.conf"; then

        echo "ERREUR : slot de réplication différent."
        exit 1
    fi

    systemctl enable --now "$PG_SERVICE"

    if [[ "$CONFIG_CHANGED" -eq 1 ]]; then
        systemctl restart "$PG_SERVICE"
    elif [[ "$HBA_CHANGED" -eq 1 ]]; then
        systemctl reload "$PG_SERVICE"
    fi

else

    # --------------------------------------------------------
    # 8. Première initialisation d'une VM neuve
    # --------------------------------------------------------

    echo "Préparation de la nouvelle réplique..."

    if [[ -e "$STAGING" || -e "$BACKUP" ]]; then
        echo "ERREUR : répertoire temporaire déjà présent."
        echo "Intervention manuelle nécessaire."
        exit 1
    fi

    # La VM neuve vient d'installer PostgreSQL.
    # Vérifier que le cluster initial est vide.

    USER_DATABASES="$(
        runuser -u postgres -- psql \
            -X -At -v ON_ERROR_STOP=1 \
            -d postgres \
            -c "SELECT COUNT(*)
                FROM pg_database
                WHERE datname NOT IN
                ('postgres', 'template0', 'template1');"
    )"

    if [[ "$USER_DATABASES" != "0" ]]; then
        echo "ERREUR : le cluster possède des bases utilisateur."
        echo "Abandon pour protéger les données."
        exit 1
    fi

    # Arrêter le cluster Ubuntu initial.

    systemctl stop "$PG_SERVICE"

    # Empêcher le démarrage automatique pendant
    # la reconstruction.

    systemctl disable "$PG_SERVICE"

    # --------------------------------------------------------
    # 9. Sauvegarde physique depuis le nouveau primaire
    # --------------------------------------------------------

    echo "Copie depuis ${PRIMARY_IP}..."

    # pg_basebackup :
    #   Le slot est préalablement créé par scripts/bdd.sh.
    #   -S utilise ce slot.
    #   -R configure automatiquement standby.signal
    #      et les paramètres de connexion.
    #
    # pg_basebackup utilise le slot existant sans le recréer.

    runuser -u postgres -- pg_basebackup \
        --dbname="host=${PRIMARY_IP} port=5432 user=${REPLICA_USER} passfile=${PASSFILE} application_name=${REPLICA_NAME}" \
        --pgdata="$STAGING" \
        --wal-method=stream \
        --slot="$SLOT_NAME" \
        --write-recovery-conf \
        --no-password \
        --progress

    # --------------------------------------------------------
    # 10. Vérifier la sauvegarde avant installation
    # --------------------------------------------------------

    if [[ ! -f "${STAGING}/standby.signal" ]]; then
        echo "ERREUR : standby.signal absent."
        exit 1
    fi

    if [[ ! -f "${STAGING}/PG_VERSION" ]]; then
        echo "ERREUR : sauvegarde PostgreSQL incomplète."
        exit 1
    fi

    # Sauvegarder l'ancien cluster vide fourni par Ubuntu.

    mv "$PG_DATA" "$BACKUP"

    # Installer la nouvelle base répliquée.

    mv "$STAGING" "$PG_DATA"

    chown -R postgres:postgres "$PG_DATA"
    chmod 0700 "$PG_DATA"

    # Démarrer PostgreSQL uniquement maintenant,
    # lorsque standby.signal est présent.

    systemctl enable --now "$PG_SERVICE"

fi

# ------------------------------------------------------------
# 11. Confirmer le rôle de réplique
# ------------------------------------------------------------

IS_STANDBY="$(
    runuser -u postgres -- psql \
        -X -At -v ON_ERROR_STOP=1 \
        -d postgres \
        -c "SELECT pg_is_in_recovery();"
)"

if [[ "$IS_STANDBY" != "t" ]]; then
    echo "ERREUR CRITIQUE : PostgreSQL n'est pas une réplique."
    exit 1
fi

echo "Rôle PostgreSQL confirmé : réplique."

# ------------------------------------------------------------
# 12. Vérifier les données répliquées
# ------------------------------------------------------------

NB_RESULTATS=0

for tentative in {1..15}; do

    NB_RESULTATS="$(
        runuser -u postgres -- psql \
            -X -At -v ON_ERROR_STOP=1 \
            -d "$DB_NAME" \
            -c "SELECT COUNT(*) FROM public.resultats;" \
            2>/dev/null || true
    )"

    if [[ "$NB_RESULTATS" =~ ^[0-9]+$ ]] &&
       (( NB_RESULTATS >= 50000 )); then
        break
    fi

    sleep 2

done

echo "Nombre de candidats sur ${REPLICA_NAME} : ${NB_RESULTATS}"

if [[ ! "$NB_RESULTATS" =~ ^[0-9]+$ ]] ||
   (( NB_RESULTATS < 50000 )); then
    echo "ERREUR : réplication des données non confirmée."
    exit 1
fi

# ------------------------------------------------------------
# 13. Vérifier la connexion au primaire
# ------------------------------------------------------------

RECEIVER_STATUS="$(
    runuser -u postgres -- psql \
        -X -At -v ON_ERROR_STOP=1 \
        -d postgres \
        -c "SELECT COUNT(*)
            FROM pg_stat_wal_receiver
            WHERE status = 'streaming';"
)"

if [[ "$RECEIVER_STATUS" != "1" ]]; then
    echo "ERREUR : WAL receiver non connecté en streaming."
    exit 1
fi

echo "============================================"
echo " PostgreSQL réplique opérationnelle"
echo " Primaire : ${PRIMARY_IP}"
echo " Réplique : ${REPLICA_NAME}"
echo " Slot     : ${SLOT_NAME}"
echo " Candidats: ${NB_RESULTATS}"
echo " Streaming: actif"
echo "============================================"
