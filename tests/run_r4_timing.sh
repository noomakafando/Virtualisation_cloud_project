
#!/usr/bin/env bash
set -euo pipefail

echo "=== TEST AUTOMATIQUE R4 ==="

restaurer() {
    echo "Rétablissement de app1..."
    vagrant ssh app1 -c \
        "sudo systemctl start resultats-bf.service"
}

trap restaurer EXIT

echo "Démarrage de la surveillance sur lb1..."

vagrant ssh lb1 -c \
    "sudo python3 -u /vagrant/tests/test_r4_timing.py" &

MONITOR_PID=$!

# Laisser la surveillance vérifier l'état initial.
sleep 2

echo "Arrêt du service sur app1..."

vagrant ssh app1 -c \
    "sudo systemctl stop resultats-bf.service"

# Attendre le résultat du test de surveillance.
wait "$MONITOR_PID"

echo "=== TEST R4 TERMINÉ ==="
