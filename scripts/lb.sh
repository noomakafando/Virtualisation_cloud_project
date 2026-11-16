
#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# RESULTATS-BF — Provisionnement du répartiteur HAProxy
# ============================================================

SOURCE_CONFIG="/vagrant/config/haproxy/haproxy.cfg"
TARGET_CONFIG="/etc/haproxy/haproxy.cfg"

echo "=== Provisionnement HAProxy sur $(hostname) ==="

# 1. Installer HAProxy si nécessaire.
if ! dpkg-query -W -f='${Status}' haproxy 2>/dev/null \
    | grep -qx "install ok installed"; then

    apt-get update -qq

    DEBIAN_FRONTEND=noninteractive \
        apt-get install -y haproxy
fi

# 2. Vérifier le fichier généré sur l'hôte.
if [[ ! -f "$SOURCE_CONFIG" ]]; then
    echo "ERREUR : configuration HAProxy introuvable."
    exit 1
fi

# 3. Installer la configuration.
# Ne pas remplacer le fichier si rien n'a changé.
CONFIG_CHANGED=0

if ! cmp -s "$SOURCE_CONFIG" "$TARGET_CONFIG"; then
    install -o root -g root -m 0644 \
        "$SOURCE_CONFIG" "$TARGET_CONFIG"
    CONFIG_CHANGED=1
fi

# 4. Vérifier la syntaxe avant d'activer le service.
haproxy -c -f "$TARGET_CONFIG"

# 5. Activer le service au démarrage.
systemctl enable --now haproxy

# 6. Recharger uniquement si la configuration a changé.
if [[ "$CONFIG_CHANGED" -eq 1 ]]; then
    systemctl reload-or-restart haproxy
fi

# 7. Vérifier l'état final.
if ! systemctl is-active --quiet haproxy; then
    echo "ERREUR : HAProxy n'est pas actif."
    exit 1
fi

echo "=== HAProxy opérationnel ==="
