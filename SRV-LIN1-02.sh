#!/bin/bash
# shellcheck disable=SC2016  # mots de passe volontairement entre guillemets simples ($ litteral)
#
# ============================================================================
# SRV-LIN1-02.sh
# ----------------------------------------------------------------------------
# Installation et configuration automatisees de SRV-LIN1-02 (Nextcloud)
# Module LIN1 (CPNV) - Infrastructure LIN1-LABO
# Auteur : Danis
#
# ROLE DE LA MACHINE
#   SRV-LIN1-02 heberge Nextcloud, le service de partage de fichiers de
#   LIN1-LABO. Les comptes viennent de l'annuaire LDAP de SRV-LIN1-01 et
#   les fichiers sont stockes sur le NAS (partage NFS), pas sur ce serveur.
#
# CE QUE FAIT LE SCRIPT (dans l'ordre)
#   [1/8] Reseau          : ens33 en statique 10.10.10.22/24,
#                           passerelle et DNS = SRV-LIN1-01
#   [2/8] Partage du NAS  : montage NFS de nextcloud-data sur /mnt/nas-data
#   [3/8] Apache, MariaDB, PHP
#   [4/8] Nextcloud HTTPS : certificat auto-signe, URL /nextcloud,
#                           donnees dans /mnt/nas-data/ncdata (sur le NAS)
#   [5/8] LDAP            : utilisateurs et groupes de SRV-LIN1-01,
#                           quota personnel de 10 Mo
#   [6/8] Dossiers d'equipe Clients / Logiciels / Commun : droits par
#                           groupe (doc 4 "Arborescence") et quotas
#   [7/8] Espaces "Perso" : un dossier personnel par utilisateur sur le NAS
#   [8/8] Calendrier
#   Puis : AUTO-CONTROLE final (OK / ECHEC).
#
# PREREQUIS
#   - SRV-LIN1-01 operationnel (DNS, DHCP, LDAP, acces Internet par NAT).
#   - NAS-LIN1-01 operationnel, export NFS "nextcloud-data" autorise pour
#     10.10.10.22. Sur le NAS, en root, creer UNE FOIS les dossiers
#     appartenant a www-data (UID/GID 33) :
#         cd /srv/dev-disk-by-uuid-*/nextcloud-data/
#         mkdir ncdata && chown 33:33 ncdata && chmod 770 ncdata
#         for u in man01 man02 ing01 ing02 dev01; do
#             mkdir perso-$u && chown 33:33 perso-$u && chmod 770 perso-$u
#         done
#     Pourquoi sur le NAS ? Le root de SRV-LIN1-02 ne peut pas le faire a
#     travers NFS : l'option root_squash le transforme en "nobody".
#   - Debian 12 (Bookworm) fraichement installee, une seule carte reseau
#     ens33 (Host-only VMnet2). Verifier avec "ip link", sinon adapter
#     IFACE_LAN ci-dessous.
#
# UTILISATION
#   Depuis la console VMware (pas en SSH : le script change l'adresse IP,
#   une session SSH serait coupee en cours) :
#       su -
#       bash SRV-LIN1-02.sh
#   Duree : 10 a 20 minutes (telechargement de Nextcloud).
#   Tout l'affichage est aussi enregistre dans /var/log/SRV-LIN1-02.log
#
# ETAPES VOLONTAIREMENT NON AUTOMATISEES (voir documentation)
#   - Authentification SSH par cle (cle publique du poste d'administration).
#   - Utilisateur dev02 : cree pendant le POC (point 30). Il herite
#     automatiquement des droits de son groupe et du quota par defaut ;
#     son espace Perso est ajoute pendant la demonstration (point 32).
# ============================================================================


# ============================================================================
# 0. VERIFICATIONS, JOURNAL ET VARIABLES
# ============================================================================

if [ "$EUID" -ne 0 ]; then
    echo "Ce script doit etre execute en root : su - puis bash SRV-LIN1-02.sh"
    exit 1
fi

# Journal : tout ce qui s'affiche est aussi ecrit dans le fichier de log
LOG_FILE="/var/log/SRV-LIN1-02.log"
exec > >(tee -a "${LOG_FILE}") 2>&1

# Arret immediat a la premiere erreur, avec le numero de la ligne fautive
set -e
trap 'echo ""; echo "ERREUR a la ligne ${LINENO}. Voir ${LOG_FILE}"; exit 1' ERR

export DEBIAN_FRONTEND=noninteractive

# --- Reseau ---
IFACE_LAN="ens33"
IP_SRV02="10.10.10.22"
NETMASK="255.255.255.0"
GATEWAY="10.10.10.11"            # SRV-LIN1-01 (NAT vers Internet)
DNS_SERVER="10.10.10.11"         # SRV-LIN1-01 (BIND9)
DOMAIN="lin1-labo.local"

# --- Partage du NAS ---
NAS_IP="10.10.10.33"
NAS_EXPORT="/nextcloud-data"              # nom de l'export NFS sur le NAS
NFS_MOUNT_POINT="/mnt/nas-data"           # ou il apparait sur ce serveur
NC_DATA_DIR="${NFS_MOUNT_POINT}/ncdata"   # donnees Nextcloud (sur le NAS)

# --- Nextcloud ---
NC_DIR="/var/www/nextcloud"
NC_MAJOR="34"                    # derniere branche compatible PHP 8.2 (Debian 12)
NC_FALLBACK_VERSION="34.0.4"     # version GitHub si download.nextcloud.com echoue
# Versions des applications compatibles Nextcloud 34, utilisees si l'app
# store est indisponible (erreur 429 rencontree depuis le reseau CPNV)
GROUPFOLDERS_VERSION="22.0.6"
CALENDAR_VERSION="6.5.4"
NC_URL="https://${IP_SRV02}/nextcloud"
NC_ADMIN_USER="ncadmin"
NC_ADMIN_PASSWORD='Pa$$w0rd'     # guillemets simples : $ non interprete

# --- Base de donnees de Nextcloud (locale, MariaDB) ---
DB_NAME="nextcloud"
DB_USER="nextclouduser"
DB_PASSWORD='Pa$$w0rd'

# --- Annuaire LDAP (SRV-LIN1-01) ---
LDAP_HOST="10.10.10.11"
LDAP_BASE_DN="dc=lin1-labo,dc=local"
LDAP_ADMIN_DN="cn=admin,dc=lin1-labo,dc=local"
LDAP_ADMIN_PASSWORD='Pa$$w0rd'
LDAP_USERS="man01 man02 ing01 ing02 dev01"   # utilisateurs crees par SRV-LIN1-01.sh
LDAP_USER_PASSWORD='Pa$$w0rd'                # sert uniquement a l'auto-controle

# Raccourci vers occ, l'outil d'administration en ligne de commande de
# Nextcloud. Il doit tourner avec l'utilisateur d'Apache (www-data).
occ() {
    sudo -u www-data php "${NC_DIR}/occ" "$@"
}

echo "============================================================"
echo " SRV-LIN1-02 - Debut de l'installation automatisee"
echo " $(date '+%d.%m.%Y %H:%M:%S')"
echo "============================================================"

hostnamectl set-hostname srv-lin1-02
sed -i '/127.0.1.1/d' /etc/hosts
echo "127.0.1.1 srv-lin1-02.${DOMAIN} srv-lin1-02" >> /etc/hosts


# ============================================================================
# 1. RESEAU
# ============================================================================
# Adresse fixe : les clients et le NAS (export NFS autorise pour .22)
# doivent toujours trouver Nextcloud a la meme adresse.
echo ""
echo "---- [1/8] Configuration reseau ----"

# Libere l'adresse DHCP obtenue a l'installation (avec l'ancienne
# configuration), sinon elle resterait active a cote de l'adresse statique.
ifdown "${IFACE_LAN}" 2>/dev/null || true

cat > /etc/network/interfaces <<EOF
source /etc/network/interfaces.d/*

auto lo
iface lo inet loopback

# Carte interne - VMnet2 Host-only (reseau LIN1-LABO)
auto ${IFACE_LAN}
iface ${IFACE_LAN} inet static
    address ${IP_SRV02}
    netmask ${NETMASK}
    gateway ${GATEWAY}
EOF

# DNS ecrit directement (l'option dns-nameservers exigerait le paquet
# resolvconf). "search" permet d'ecrire srv-lin1-01 sans le domaine.
cat > /etc/resolv.conf <<EOF
domain ${DOMAIN}
search ${DOMAIN}
nameserver ${DNS_SERVER}
EOF

ifup "${IFACE_LAN}" 2>/dev/null || systemctl restart networking || true

# Sans passerelle ni Internet, la suite (apt, Nextcloud) echouerait :
# on le signale tout de suite.
echo "Test de la connectivite (passerelle et Internet via SRV-LIN1-01)..."
ping -c 2 "${GATEWAY}" >/dev/null && echo "  passerelle OK" \
    || echo "  ATTENTION : passerelle ${GATEWAY} injoignable"
ping -c 2 debian.org >/dev/null && echo "  Internet OK" \
    || echo "  ATTENTION : pas d'Internet (verifier le NAT et le DNS de SRV-LIN1-01)"


# ============================================================================
# 2. MONTAGE DU PARTAGE NFS DU NAS
# ============================================================================
# Les fichiers des utilisateurs ne restent pas sur SRV-LIN1-02 : ils sont
# ecrits sur le NAS (RAID 1) a travers ce montage.
echo ""
echo "---- [2/8] Montage du partage NFS du NAS ----"

apt update
apt install -y sudo vim wget curl unzip nfs-common

mkdir -p "${NFS_MOUNT_POINT}"
if ! grep -q "${NFS_MOUNT_POINT}" /etc/fstab; then
    # Options du montage :
    #   _netdev              : attendre le reseau avant de monter
    #   x-systemd.automount  : monter au premier acces. Evite un echec
    #                          definitif si SRV-LIN1-02 demarre avant le NAS.
    #   x-systemd.mount-timeout=30 : abandonner apres 30 s si le NAS ne repond pas
    echo "${NAS_IP}:${NAS_EXPORT} ${NFS_MOUNT_POINT} nfs defaults,_netdev,x-systemd.automount,x-systemd.mount-timeout=30 0 0" >> /etc/fstab
fi
systemctl daemon-reload
mountpoint -q "${NFS_MOUNT_POINT}" || mount "${NFS_MOUNT_POINT}"

# www-data (Apache/Nextcloud) doit pouvoir ecrire dans ncdata, sinon
# l'installation de Nextcloud echouerait plus loin avec un message obscur.
if ! sudo -u www-data test -w "${NC_DATA_DIR}"; then
    echo "ERREUR : ${NC_DATA_DIR} n'existe pas ou n'est pas accessible en ecriture"
    echo "par www-data. Creer le dossier sur le NAS (voir PREREQUIS en tete de script)."
    exit 1
fi
echo "Partage monte : ${NAS_IP}:${NAS_EXPORT} -> ${NFS_MOUNT_POINT}"


# ============================================================================
# 3. APACHE, MARIADB, PHP
# ============================================================================
# Apache sert les pages, PHP execute Nextcloud, MariaDB stocke les
# metadonnees (utilisateurs, partages, calendriers...). Les modules PHP
# sont ceux exiges par Nextcloud (ldap pour l'annuaire, imagick pour les
# apercus, intl/mbstring pour le texte, etc.).
echo ""
echo "---- [3/8] Apache, MariaDB, PHP ----"

apt install -y apache2 mariadb-server libapache2-mod-php \
    php php-gd php-mysql php-curl php-mbstring php-intl php-gmp \
    php-bcmath php-xml php-imagick php-zip php-ldap

# Equivalent non interactif de mysql_secure_installation (suppression des
# comptes anonymes et de la base de test), puis creation de la base et de
# l'utilisateur dedie a Nextcloud (droits limites a sa base).
mysql -u root <<EOF
DELETE FROM mysql.global_priv WHERE User='';
DROP DATABASE IF EXISTS test;
CREATE DATABASE IF NOT EXISTS ${DB_NAME} CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASSWORD}';
GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
EOF

# Limite memoire PHP recommandee par Nextcloud (fichier utilise par Apache)
for INI in /etc/php/*/apache2/php.ini; do
    sed -i 's/^memory_limit = .*/memory_limit = 512M/' "${INI}"
done


# ============================================================================
# 4. NEXTCLOUD EN HTTPS
# ============================================================================
echo ""
echo "---- [4/8] Installation de Nextcloud (HTTPS) ----"

# Branche 34 imposee : Nextcloud 35 (latest.zip) exige PHP 8.3, alors que
# Debian 12 fournit PHP 8.2. Nextcloud 34 supporte PHP 8.2 a 8.5.
# En secours, la meme version est prise sur GitHub.
if [ ! -d "${NC_DIR}" ]; then
    cd /tmp
    if ! wget -q "https://download.nextcloud.com/server/releases/latest-${NC_MAJOR}.zip" -O nextcloud.zip; then
        echo "download.nextcloud.com indisponible, telechargement depuis GitHub..."
        wget -q "https://github.com/nextcloud-releases/server/releases/download/v${NC_FALLBACK_VERSION}/nextcloud-${NC_FALLBACK_VERSION}.zip" -O nextcloud.zip
    fi
    unzip -q nextcloud.zip -d /var/www/
    rm -f nextcloud.zip
fi
chown -R www-data:www-data "${NC_DIR}"

# Certificat auto-signe valable 1 an (cle RSA 2048 bits). Le navigateur
# affiche un avertissement : normal, aucune autorite ne l'a signe.
# En production : certificat Let's Encrypt ou autorite interne.
mkdir -p /etc/ssl/nextcloud
if [ ! -s /etc/ssl/nextcloud/nextcloud.crt ]; then
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout /etc/ssl/nextcloud/nextcloud.key \
        -out /etc/ssl/nextcloud/nextcloud.crt \
        -subj "/C=CH/ST=Vaud/O=LIN1-LABO/OU=IT/CN=srv-lin1-02.${DOMAIN}"
fi
chmod 600 /etc/ssl/nextcloud/nextcloud.key

# Deux sites Apache : HTTP (port 80) et HTTPS (port 443).
# DocumentRoot = /var/www/ pour que Nextcloud reponde sur /nextcloud
# (URL exigee par le point 15 du POC : https://10.10.10.22/nextcloud).
#   AllowOverride All : Nextcloud a besoin de son .htaccess
#   Dav off           : Nextcloud gere lui-meme WebDAV
for MODE in http https; do
    if [ "${MODE}" = "http" ]; then
        FILE=/etc/apache2/sites-available/nextcloud.conf
        HEAD="<VirtualHost *:80>"
        SSL=""
    else
        FILE=/etc/apache2/sites-available/nextcloud-ssl.conf
        HEAD="<VirtualHost *:443>"
        SSL="    SSLEngine on
    SSLCertificateFile /etc/ssl/nextcloud/nextcloud.crt
    SSLCertificateKeyFile /etc/ssl/nextcloud/nextcloud.key"
    fi
    cat > "${FILE}" <<EOF
${HEAD}
    DocumentRoot /var/www/
    ServerName srv-lin1-02.${DOMAIN}
${SSL}

    <Directory /var/www/nextcloud/>
        Require all granted
        AllowOverride All
        Options FollowSymLinks MultiViews
        <IfModule mod_dav.c>
            Dav off
        </IfModule>
    </Directory>

    ErrorLog \${APACHE_LOG_DIR}/nextcloud_${MODE}_error.log
    CustomLog \${APACHE_LOG_DIR}/nextcloud_${MODE}_access.log combined
</VirtualHost>
EOF
done

a2enmod ssl rewrite headers env dir mime setenvif >/dev/null
a2ensite nextcloud.conf nextcloud-ssl.conf >/dev/null
# Le site par defaut prendrait la priorite sur Nextcloud (probleme rencontre)
a2dissite 000-default.conf >/dev/null 2>&1 || true
# Verification de la syntaxe Apache avant redemarrage
apache2ctl configtest
systemctl restart apache2

# Installation non interactive (equivalent de l'assistant web).
# --data-dir place les donnees directement sur le NAS.
if ! occ status 2>/dev/null | grep -q "installed: true"; then
    occ maintenance:install \
        --database "mysql" \
        --database-name "${DB_NAME}" \
        --database-user "${DB_USER}" \
        --database-pass "${DB_PASSWORD}" \
        --admin-user "${NC_ADMIN_USER}" \
        --admin-pass "${NC_ADMIN_PASSWORD}" \
        --data-dir "${NC_DATA_DIR}"
fi

# Pas de fichiers d'exemple pour les nouveaux utilisateurs : ils pesent
# 63 Mo et rempliraient a eux seuls le quota personnel de 10 Mo.
occ config:system:set skeletondirectory --value=""
occ config:system:set templatedirectory --value=""

# Adresses par lesquelles Nextcloud accepte d'etre appele
# (index 0 = localhost, pose par l'installation)
occ config:system:set trusted_domains 1 --value="${IP_SRV02}"
occ config:system:set trusted_domains 2 --value="srv-lin1-02.${DOMAIN}"
occ config:system:set overwrite.cli.url --value="${NC_URL}"

echo "Nextcloud installe : ${NC_URL} (donnees sur le NAS : ${NC_DATA_DIR})"


# ============================================================================
# 5. AUTHENTIFICATION LDAP
# ============================================================================
# Nextcloud ne cree pas ses propres comptes : il interroge l'annuaire de
# SRV-LIN1-01. Un utilisateur ajoute dans LDAP (ex. dev02) peut se
# connecter tout de suite, avec les droits de son groupe.
echo ""
echo "---- [5/8] Connexion a l'annuaire LDAP ----"

occ app:enable user_ldap

# Configuration "s01" (premiere configuration LDAP de Nextcloud)
if ! occ ldap:show-config s01 >/dev/null 2>&1; then
    occ ldap:create-empty-config
fi

# Serveur et compte de lecture de l'annuaire
occ ldap:set-config s01 ldapHost "ldap://${LDAP_HOST}"
occ ldap:set-config s01 ldapPort 389
occ ldap:set-config s01 ldapAgentName "${LDAP_ADMIN_DN}"
occ ldap:set-config s01 ldapAgentPassword "${LDAP_ADMIN_PASSWORD}"
occ ldap:set-config s01 ldapBase "${LDAP_BASE_DN}"
occ ldap:set-config s01 ldapBaseUsers "ou=people,${LDAP_BASE_DN}"
occ ldap:set-config s01 ldapBaseGroups "ou=groups,${LDAP_BASE_DN}"

# Utilisateurs : comptes inetOrgPerson, connexion avec l'uid (ex. dev01)
occ ldap:set-config s01 ldapUserFilterObjectclass inetOrgPerson
occ ldap:set-config s01 ldapUserFilter "(objectclass=inetOrgPerson)"
occ ldap:set-config s01 ldapLoginFilter "(&(objectclass=inetOrgPerson)(uid=%uid))"
occ ldap:set-config s01 ldapLoginFilterUsername 1
occ ldap:set-config s01 ldapUserDisplayName displayName
# Identifiant interne = uid (man01...) au lieu d'un UUID illisible
occ ldap:set-config s01 ldapExpertUsernameAttr uid

# Groupes : posixGroup, appartenance via memberUid (point bloquant
# rencontre : sans ce reglage, les utilisateurs n'apparaissent dans aucun
# groupe et n'ont donc acces a aucun dossier d'equipe)
occ ldap:set-config s01 ldapGroupFilterObjectclass posixGroup
occ ldap:set-config s01 ldapGroupFilter "(objectclass=posixGroup)"
occ ldap:set-config s01 ldapGroupDisplayName cn
occ ldap:set-config s01 ldapGroupMemberAssocAttr memberUid

# Quota par defaut des utilisateurs LDAP = espace personnel de 10 Mo
occ ldap:set-config s01 ldapQuotaDefault "10 MB"

occ ldap:set-config s01 ldapConfigurationActive 1
# Teste la connexion et le compte cn=admin (arret du script si invalide)
occ ldap:test-config s01

# Premiere lecture de l'annuaire : Nextcloud enregistre les utilisateurs
# et les groupes (necessaire pour leur attribuer des droits a l'etape 6)
occ user:list
occ group:list


# ============================================================================
# 6. DOSSIERS D'EQUIPE (Team Folders) : DROITS ET QUOTAS
# ============================================================================
# Un dossier d'equipe appartient a Nextcloud (pas a un utilisateur) et
# apparait automatiquement chez les membres des groupes autorises.
# Ses fichiers sont dans ncdata/__groupfolders/, donc sur le NAS.
echo ""
echo "---- [6/8] Dossiers d'equipe Clients / Logiciels / Commun ----"

# Installe une application : app store d'abord (il choisit la version
# compatible), sinon la version figee publiee sur GitHub. La "derniere"
# release GitHub ne convient pas : elle peut viser une autre version de
# Nextcloud (pour groupfolders, c'etait une version pour Nextcloud 32).
install_app() {
    local APP="$1" VERSION="$2"
    if occ app:install "${APP}" >/dev/null 2>&1 || occ app:enable "${APP}" >/dev/null 2>&1; then
        echo "Application ${APP} installee depuis l'app store."
        return 0
    fi
    echo "App store indisponible pour ${APP}, version ${VERSION} depuis GitHub..."
    wget -q "https://github.com/nextcloud-releases/${APP}/releases/download/v${VERSION}/${APP}-v${VERSION}.tar.gz" \
        -O "/tmp/${APP}.tar.gz"
    rm -rf "${NC_DIR}/apps/${APP}"
    tar -xzf "/tmp/${APP}.tar.gz" -C "${NC_DIR}/apps/"
    chown -R www-data:www-data "${NC_DIR}/apps/${APP}"
    rm -f "/tmp/${APP}.tar.gz"
    occ app:enable "${APP}"
}

install_app groupfolders "${GROUPFOLDERS_VERSION}"

# Cree un dossier d'equipe s'il n'existe pas encore et renvoie son
# numero (le script peut ainsi etre relance sans creer de doublons)
create_folder() {
    local NAME="$1" ID
    ID=$(occ groupfolders:list --output=json 2>/dev/null | php -r '
        foreach (json_decode(stream_get_contents(STDIN), true) ?: [] as $f) {
            if ($f["mountPoint"] === $argv[1]) { echo $f["id"]; break; }
        }' "${NAME}")
    if [ -z "${ID}" ]; then
        ID=$(occ groupfolders:create "${NAME}" | grep -o '[0-9]\+' | tail -1)
    fi
    echo "${ID}"
}

ID_CLIENTS=$(create_folder Clients)
ID_LOGICIELS=$(create_folder Logiciels)
ID_COMMUN=$(create_folder Commun)

# Droits (doc 4 - Arborescence des donnees) :
#
#   Dossier     | manager        | ingenieur        | developpeur
#   ------------+----------------+------------------+-----------------
#   Clients     | lecture/ecrit. | -                | -
#   Logiciels   | -              | lecture/ecrit.   | lecture/ecrit.
#   Commun      | lecture seule  | lecture/ecrit.   | lecture/ecrit.
#
# Syntaxe : groupfolders:group <dossier> <groupe> [permissions]
#   "write share delete" = lecture + ecriture, partage, suppression
#   aucune permission    = lecture seule
occ groupfolders:group "${ID_CLIENTS}"   manager     write share delete
occ groupfolders:group "${ID_LOGICIELS}" ingenieur   write share delete
occ groupfolders:group "${ID_LOGICIELS}" developpeur write share delete
occ groupfolders:group "${ID_COMMUN}"    ingenieur   write share delete
occ groupfolders:group "${ID_COMMUN}"    developpeur write share delete
occ groupfolders:group "${ID_COMMUN}"    manager

# Quotas (en octets) : Clients 20 Mo, Logiciels 20 Mo, Commun 30 Mo
occ groupfolders:quota "${ID_CLIENTS}"   20971520
occ groupfolders:quota "${ID_LOGICIELS}" 20971520
occ groupfolders:quota "${ID_COMMUN}"    31457280

occ groupfolders:list


# ============================================================================
# 7. ESPACES PERSONNELS "Perso" SUR LE NAS
# ============================================================================
# Chaque utilisateur voit un dossier "Perso" qui pointe vers son dossier
# perso-<uid> sur le NAS (application "Stockage externe", type Local).
# Le stockage n'est visible QUE par son proprietaire.
# Les dossiers perso-<uid> sont crees sur le NAS (voir PREREQUIS) ; un
# dossier absent est signale mais n'arrete pas le script.
echo ""
echo "---- [7/8] Espaces personnels Perso ----"

occ app:enable files_external
# Autorise les stockages de type "Local" (desactives par defaut dans les
# versions recentes, car ils donnent acces a un dossier du serveur)
occ config:system:set files_external_allow_create_new_local --value=true --type=boolean

for U in ${LDAP_USERS}; do
    PERSO_DIR="${NFS_MOUNT_POINT}/perso-${U}"
    if ! sudo -u www-data test -w "${PERSO_DIR}"; then
        echo "  ATTENTION : ${PERSO_DIR} absent ou non inscriptible : Perso de ${U} non cree."
        continue
    fi
    # Deja configure ? (le chemin apparait dans la liste des stockages)
    if occ files_external:list --output=json | grep -q "perso-${U}\""; then
        echo "  Perso de ${U} : deja configure"
        continue
    fi
    # Creation du stockage, puis restriction a son seul proprietaire
    STORAGE_ID=$(occ files_external:create Perso local null::null \
        -c "datadir=${PERSO_DIR}" | grep -o '[0-9]\+' | tail -1)
    occ files_external:applicable --add-user="${U}" "${STORAGE_ID}" >/dev/null
    echo "  Perso de ${U} -> ${PERSO_DIR}"
done


# ============================================================================
# 8. CALENDRIER
# ============================================================================
echo ""
echo "---- [8/8] Application Calendrier ----"

install_app calendar "${CALENDAR_VERSION}" \
    || echo "ATTENTION : Calendrier a installer a la main (voir documentation)."


# ============================================================================
# AUTO-CONTROLE
# ============================================================================
# Chaque element est teste apres l'installation. Un ECHEC n'arrete pas le
# script : il indique ce qu'il faut verifier (voir documentation,
# section depannage du service concerne).
trap - ERR
set +e
ECHECS=0

controle() {
    # $1 = description, $2 = commande a tester
    if eval "$2" >/dev/null 2>&1; then
        echo "  [OK]     $1"
    else
        echo "  [ECHEC]  $1"
        ECHECS=$((ECHECS + 1))
    fi
}

# Contenu de la racine de dev01 vu par WebDAV, comme le ferait un client
# (connexion reelle avec son mot de passe LDAP)
# shellcheck disable=SC2034  # utilisee dans les controles (eval)
DAV_DEV01=$(curl -sk -u "dev01:${LDAP_USER_PASSWORD}" -X PROPFIND -H "Depth: 1" \
    "https://${IP_SRV02}/nextcloud/remote.php/dav/files/dev01/" 2>/dev/null)

echo ""
echo "---- Auto-controle ----"
controle "Adresse ${IP_SRV02} sur ${IFACE_LAN}" \
    "ip -4 addr show ${IFACE_LAN} | grep -q ' ${IP_SRV02}/'"
controle "DNS : srv-lin1-01 -> 10.10.10.11" \
    "getent hosts srv-lin1-01 | grep -q 10.10.10.11"
controle "Internet : ping www.google.com" \
    "ping -c 1 -W 3 www.google.com"
controle "Partage NFS du NAS monte sur ${NFS_MOUNT_POINT}" \
    "ls ${NFS_MOUNT_POINT} && mount | grep -q 'on ${NFS_MOUNT_POINT} type nfs'"
controle "Nextcloud installe" \
    "occ status | grep -q 'installed: true'"
controle "Donnees Nextcloud sur le NAS (${NC_DATA_DIR})" \
    "[ \"\$(occ config:system:get datadirectory)\" = '${NC_DATA_DIR}' ]"
controle "HTTPS : ${NC_URL}" \
    "curl -sk -o /dev/null -w '%{http_code}' https://${IP_SRV02}/nextcloud/status.php | grep -q 200"
controle "LDAP : configuration valide" \
    "occ ldap:test-config s01 | grep -qi valid"
controle "LDAP : dev01 connu et membre de developpeur" \
    "occ user:info dev01 | grep -q developpeur"
controle "LDAP : quota par defaut de 10 MB" \
    "occ ldap:show-config s01 | grep ldapQuotaDefault | grep -q '10 MB'"
controle "3 dossiers d'equipe (Clients, Logiciels, Commun)" \
    "[ \"\$(occ groupfolders:list --output=json | grep -o '\"mountPoint\":\"[A-Za-z]*\"' | wc -l)\" -ge 3 ]"
controle "dev01 se connecte et voit Commun et Logiciels" \
    "echo \"\${DAV_DEV01}\" | grep -q Commun && echo \"\${DAV_DEV01}\" | grep -q Logiciels"
controle "dev01 ne voit pas Clients" \
    "! echo \"\${DAV_DEV01}\" | grep -q Clients"
controle "dev01 voit son espace Perso" \
    "echo \"\${DAV_DEV01}\" | grep -q Perso"
controle "Application Calendrier activee" \
    "occ config:app:get calendar enabled | grep -q yes"


# ============================================================================
# FIN
# ============================================================================
echo ""
echo "============================================================"
if [ "${ECHECS}" -eq 0 ]; then
    echo " SRV-LIN1-02 - Installation terminee : tous les controles OK"
else
    echo " SRV-LIN1-02 - Installation terminee : ${ECHECS} controle(s) en ECHEC"
fi
echo "============================================================"
echo " Nextcloud      : ${NC_URL}"
echo " Admin          : ${NC_ADMIN_USER}"
echo " Donnees        : ${NC_DATA_DIR} (NAS ${NAS_IP})"
echo " LDAP           : ${LDAP_HOST} (${LDAP_BASE_DN})"
echo " Team Folders   : Clients(manager) / Logiciels(ing+dev) /"
echo "                  Commun(ing+dev en ecriture, manager en lecture)"
echo " Quota perso    : 10 MB par utilisateur LDAP + dossier Perso sur le NAS"
echo " Journal        : ${LOG_FILE}"
echo ""
echo " A faire a la main : cle publique SSH dans ~/.ssh/authorized_keys"
echo "============================================================"
