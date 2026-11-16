#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

export NB_APP=2

URL="http://127.0.0.1:8081"
SERVERS=(app1 app2)

declare -A IPS=(
    [app1]="192.168.56.21"
    [app2]="192.168.56.22"
)

haproxy() {
    local action="$1"
    local server="$2"

    vagrant ssh lb1 -c \
        "sudo python3 /vagrant/tests/haproxy_admin.py ${action} ${server}" |
        tr -d '\r'
}

health() {
    local url="$1"

    curl --silent --show-error --fail \
         --max-time 3 "$url" >/dev/null
}

wait_healthy() {
    local url="$1"

    for ((attempt=1; attempt<=30; attempt++)); do
        if health "$url"; then
            return 0
        fi
        sleep 1
    done

    return 1
}

wait_haproxy_up() {
    local server="$1"
    local state

    for ((attempt=1; attempt<=30; attempt++)); do
        state="$(haproxy status "$server")"

        if [[ "$state" == UP* ]]; then
            return 0
        fi

        sleep 1
    done

    return 1
}

fail() {
    echo "ECHEC : $*" >&2
    echo "Vérifier l'état HAProxy avant toute nouvelle opération." >&2
    exit 1
}

echo "=========================================="
echo " RESULTATS-BF — ROLLING DEPLOYMENT E4"
echo "=========================================="

# Vérifier que les deux backends sont disponibles.
for server in "${SERVERS[@]}"; do
    echo "Précontrôle : ${server}"

    health "http://${IPS[$server]}:8000/sante" ||
        fail "${server} est indisponible"

    state="$(haproxy status "$server")"

    [[ "$state" == UP* ]] ||
        fail "${server} n'est pas UP dans HAProxy : $state"
done

health "$URL/sante" ||
    fail "Le point d'entrée HAProxy est indisponible"

echo "Préconditions validées."

# Déployer chaque application séparément.
for server in "${SERVERS[@]}"; do

    echo
    echo "=========================================="
    echo " Déploiement de ${server}"
    echo "=========================================="

    echo "Retrait de ${server} du répartiteur..."
    haproxy disable "$server"

    # Attendre la fin des connexions actives.
    DRAINED=0

    for ((attempt=1; attempt<=30; attempt++)); do

        read -r state connections < <(haproxy status "$server")

        if [[ "$connections" == "0" ]]; then
            DRAINED=1
            break
        fi

        sleep 1
    done

    if [[ "$DRAINED" -ne 1 ]]; then
        echo "Connexions encore actives sur ${server}."

        if health "http://${IPS[$server]}:8000/sante"; then
            haproxy enable "$server"
        fi

        fail "Drainage non terminé"
    fi

    # Vérifier que l'autre serveur continue de répondre.
    health "$URL/sante" ||
        fail "Service HAProxy indisponible pendant le drainage"

    echo "Provisionnement de ${server}..."

    if ! vagrant provision "$server"; then
        fail "Provisionnement échoué pour ${server}. Serveur laissé hors rotation."
    fi

    echo "Vérification de ${server}..."

    if ! wait_healthy "http://${IPS[$server]}:8000/sante"; then
        fail "${server} non sain après déploiement. Serveur laissé hors rotation."
    fi

    echo "Réactivation de ${server}..."
    haproxy enable "$server"

    wait_haproxy_up "$server" ||
        fail "${server} n'est pas redevenu UP dans HAProxy"

    health "$URL/sante" ||
        fail "HAProxy indisponible après réactivation"

    echo "SUCCES : ${server} déployé et réactivé."

done

echo
echo "=========================================="
echo " ROLLING DEPLOYMENT TERMINE"
echo " Les deux applications sont opérationnelles"
echo "=========================================="
