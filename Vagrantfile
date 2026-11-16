
# -*- mode: ruby -*-

require 'yaml'
require 'fileutils'

# ============================================================
# PROJET RESULTATS-BF — GROUPE 9
# Infrastructure DevOps avec Vagrant et VirtualBox
# ============================================================

# ============================================================
# 1. CHARGEMENT DES SECRETS LOCAUX
# ============================================================

ENV_FILE = File.join(__dir__, ".env")

unless File.file?(ENV_FILE)
  raise "Fichier .env manquant. Copiez .env.exemple vers .env"
end

SECRETS = {}

File.foreach(ENV_FILE) do |line|
  line = line.strip

  next if line.empty? || line.start_with?("#")

  key, value = line.split("=", 2)

  unless key && value &&
         key.match?(/\A[A-Z][A-Z0-9_]*\z/) &&
         value.match?(/\A[A-Za-z0-9_-]+\z/)
    raise "Format invalide dans le fichier .env"
  end

  SECRETS[key] = value
end

%w[DB_APP_PASSWORD DB_REPL_PASSWORD].each do |key|
  if SECRETS[key].nil? ||
     SECRETS[key] == "REMPLACER_PAR_UN_SECRET"
    raise "Variable #{key} manquante dans .env"
  end
end

# ============================================================
# 2. PARAMETRES DU GROUPE ET DES SERVEURS
# ============================================================

GROUPE = 9

# Deux serveurs applicatifs par défaut.
# Exemple : NB_APP=4 vagrant up
NB_APP = Integer(ENV.fetch("NB_APP", "2"), exception: false)

unless NB_APP && NB_APP.between?(2, 10)
  raise "NB_APP doit être un entier compris entre 2 et 10"
end

# Le groupe 9 reprend le réseau du groupe 1.
INDEX_RESEAU = 1

RESEAU = "192.168.#{55 + INDEX_RESEAU}"

# ============================================================
# 3. PRIMAIRE POSTGRESQL ACTIF
# ============================================================

# Ce fichier détermine quel serveur est le primaire.
#
# 192.168.56.31 => bdd1 primaire, bdd2 réplique
# 192.168.56.32 => bdd2 primaire, bdd1 réplique

CONFIG_DIR = File.join(__dir__, "config")
FileUtils.mkdir_p(CONFIG_DIR)

PRIMARY_DB_FILE = File.join(CONFIG_DIR, "primary_db_ip")

unless File.file?(PRIMARY_DB_FILE)
  raise "Fichier config/primary_db_ip manquant"
end

PRIMARY_DB_IP = File.read(PRIMARY_DB_FILE).strip

DATABASE_IPS = [
  "#{RESEAU}.31",
  "#{RESEAU}.32"
].freeze

unless DATABASE_IPS.include?(PRIMARY_DB_IP)
  raise "Adresse PostgreSQL primaire invalide : #{PRIMARY_DB_IP}"
end

# ============================================================
# 4. IMAGE UBUNTU UTILISEE
# ============================================================

BOITE = "bento/ubuntu-24.04"
VERSION = "202510.26.0"

# ============================================================
# 5. SOURCE UNIQUE DE VERITE : LES MACHINES
# ============================================================

NOEUDS = []

# Les rôles PostgreSQL sont dynamiques.
# On ne suppose plus que bdd1 est toujours le primaire.

[
  {
    nom: "bdd1",
    ip: "#{RESEAU}.31"
  },
  {
    nom: "bdd2",
    ip: "#{RESEAU}.32"
  }
].each do |db|

  role_postgresql =
    db[:ip] == PRIMARY_DB_IP ? "bdd" : "replique"

  NOEUDS << {
    nom: db[:nom],
    ip: db[:ip],
    mem: 768,
    role: role_postgresql
  }

end

# Serveurs applicatifs paramétrables.

(1..NB_APP).each do |i|

  NOEUDS << {
    nom: "app#{i}",
    ip: "#{RESEAU}.#{20 + i}",
    mem: 512,
    role: "app"
  }

end

# Répartiteur de charge.

NOEUDS << {
  nom: "lb1",
  ip: "#{RESEAU}.11",
  mem: 512,
  role: "lb"
}

# ============================================================
# 6. GENERATION DE L'INVENTAIRE DES MACHINES
# ============================================================

# Le fichier YAML est généré depuis NOEUDS.
# Les rôles PostgreSQL y sont donc actualisés.

INVENTAIRE = NOEUDS.map do |n|
  {
    "nom" => n[:nom],
    "ip" => n[:ip],
    "mem" => n[:mem],
    "role" => n[:role]
  }
end

File.write(
  File.join(CONFIG_DIR, "noeuds.yml"),
  INVENTAIRE.to_yaml
)

# ============================================================
# 7. GENERATION AUTOMATIQUE DE HAPROXY
# ============================================================

HAPROXY_DIR = File.join(CONFIG_DIR, "haproxy")
FileUtils.mkdir_p(HAPROXY_DIR)

# Utiliser la même liste que celle des VM Vagrant.

APPLICATIONS = NOEUDS.select do |n|
  n[:role] == "app"
end

# Générer automatiquement les backends applicatifs.

SERVEURS_HAPROXY = APPLICATIONS.map do |app|
  "    server #{app[:nom]} #{app[:ip]}:8000 check"
end.join("\n")

HAPROXY_CONFIG = <<~HAPROXY
  # RESULTATS-BF — Configuration générée automatiquement
  # Ne pas modifier directement ce fichier.

  global
      log /dev/log local0
      maxconn 1000
      stats socket /run/haproxy/admin.sock mode 660 level admin

  defaults
      log global
      mode http
      option httplog

      timeout connect 2s
      timeout client 10s
      timeout server 10s
      timeout check 1s

  frontend http_entree
      bind *:80
      default_backend applications

  backend applications
      balance roundrobin

      # Vérifier la santé des applications.
      option httpchk GET /sante
      http-check expect status 200

      # Réessayer sur un autre serveur en cas d'échec.
      retries 2
      option redispatch
      retry-on conn-failure empty-response

      # Détection rapide des serveurs indisponibles.
      default-server inter 500ms fastinter 200ms fall 2 rise 2

      timeout check 500ms

  #{SERVEURS_HAPROXY}
HAPROXY

File.write(
  File.join(HAPROXY_DIR, "haproxy.cfg"),
  HAPROXY_CONFIG
)

# ============================================================
# 8. CONFIGURATION DE L'INFRASTRUCTURE VAGRANT
# ============================================================

Vagrant.configure("2") do |config|

  # Image Ubuntu commune à toutes les machines.

  config.vm.box = BOITE
  config.vm.box_version = VERSION

  # Définition dynamique des machines virtuelles.

  NOEUDS.each do |n|

    config.vm.define n[:nom] do |machine|

      # Nom d'hôte Ubuntu.

      machine.vm.hostname = n[:nom]

      # Réseau privé pour les échanges entre machines.

      machine.vm.network "private_network",
        ip: n[:ip]

      # Seul HAProxy expose le service HTTP sur l'hôte.

      if n[:role] == "lb"

        machine.vm.network "forwarded_port",
          guest: 80,
          host: 8081,
          host_ip: "127.0.0.1"

      end

      # Ressources matérielles de la VM.

      machine.vm.provider "virtualbox" do |vb|
        vb.name = "resultats-bf-#{n[:nom]}"
        vb.memory = n[:mem]
        vb.cpus = 1
      end

      # ======================================================
      # 9. PROVISIONNEMENT SELON LE ROLE
      # ======================================================

      case n[:role]

      # ------------------------------------------------------
      # POSTGRESQL PRIMAIRE
      # ------------------------------------------------------

      when "bdd"

        machine.vm.provision "shell",
          path: "scripts/bdd.sh",
          env: {
            "DB_APP_PASSWORD" =>
              SECRETS.fetch("DB_APP_PASSWORD"),

            "DB_REPL_PASSWORD" =>
              SECRETS.fetch("DB_REPL_PASSWORD"),

            "PRIMARY_IP" => n[:ip],

            "REPLICA_IP" =>
              DATABASE_IPS.find { |ip| ip != n[:ip] }
          }

      # ------------------------------------------------------
      # POSTGRESQL REPLIQUE
      # ------------------------------------------------------

      when "replique"

        machine.vm.provision "shell",
          path: "scripts/replique.sh",
          env: {
            "DB_REPL_PASSWORD" =>
              SECRETS.fetch("DB_REPL_PASSWORD"),

            "PRIMARY_IP" => PRIMARY_DB_IP,

            "REPLICA_IP" => n[:ip],

            "REPLICA_NAME" => n[:nom],

            "SLOT_NAME" => "#{n[:nom]}_slot"
          }

      # ------------------------------------------------------
      # SERVEURS APPLICATIFS
      # ------------------------------------------------------

      when "app"

        machine.vm.provision "shell",
          path: "scripts/app.sh",
          env: {
            "DB_APP_PASSWORD" =>
              SECRETS.fetch("DB_APP_PASSWORD"),

            "APP_IP" => n[:ip],

            "DB_HOST" => PRIMARY_DB_IP
          }

      # ------------------------------------------------------
      # REPARTITEUR HAPROXY
      # ------------------------------------------------------

      when "lb"

        machine.vm.provision "shell",
          path: "scripts/lb.sh"

        # E2 — Supervision légère et reproductible.
        machine.vm.provision "shell",
          path: "scripts/monitoring.sh"

      end

    end

  end

end
