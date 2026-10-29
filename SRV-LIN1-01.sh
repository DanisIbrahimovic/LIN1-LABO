#!/bin/bash
# shellcheck disable=SC2016  # mots de passe volontairement entre guillemets simples ($ litteral)
#
# ============================================================================
# SRV-LIN1-01.sh
# ----------------------------------------------------------------------------
# Installation et configuration automatisees de SRV-LIN1-01
# Module LIN1 (CPNV) - Infrastructure LIN1-LABO
# Auteur : Danis
#
# ROLE DE LA MACHINE
#   SRV-LIN1-01 est le serveur central du reseau interne 10.10.10.0/24 :
#   il fournit les adresses (DHCP), les noms (DNS), les comptes (LDAP)
#   et l'acces Internet (NAT) aux autres machines.
#
# CE QUE FAIT LE SCRIPT (dans l'ordre)
#   [1/6] Reseau             : ens34 en statique 10.10.10.11/24, ens33 en DHCP
#   [2/6] Partage Internet   : routage IPv4 + NAT (MASQUERADE) vers ens33
#   [3/6] DNS (BIND9)        : zone lin1-labo.local + zone inverse 10.10.10
#   [4/6] DHCP               : plage 10.10.10.100 - 10.10.10.200 sur ens34
#   [5/6] LDAP (OpenLDAP)    : installation + PEUPLEMENT (2 OU, 3 groupes,
#                              5 utilisateurs avec mot de passe)
#   [6/6] LAM                : interface web d'administration de l'annuaire
#   Puis : resolveur DNS local et AUTO-CONTROLE final (OK / ECHEC).
#
# PREREQUIS
#   - Debian 12 (Bookworm) fraichement installee (sans interface graphique,
#     avec "serveur SSH" et "utilitaires usuels du systeme").
#   - 2 cartes reseau :
#       ens33 = NAT (VMnet8)          -> sortie Internet
#       ens34 = Host-only (VMnet2)    -> reseau interne LIN1-LABO
#     Verifier les noms avec "ip link". S'ils different, adapter
#     IFACE_NAT et IFACE_LAN ci-dessous.
#
# UTILISATION
#   Depuis la console VMware (pas en SSH : le script redemarre le reseau,
#   ce qui couperait la session) :
#       su -
#       bash SRV-LIN1-01.sh
#
#   Les DNS de transfert (forwarders) sont ceux du CPNV par defaut. Hors de
#   l'ecole, ils sont injoignables : les passer en parametre, par exemple
#       DNS_FORWARDER_1=1.1.1.1 DNS_FORWARDER_2=9.9.9.9 bash SRV-LIN1-01.sh
#
#   Tout l'affichage est aussi enregistre dans /var/log/SRV-LIN1-01.log
#
# ETAPES VOLONTAIREMENT NON AUTOMATISEES (voir documentation)
#   - Authentification SSH par cle : la cle publique du poste
#     d'administration ne peut pas etre connue a l'avance par le script.
#   - Utilisateur dev02 : sa creation fait partie de la demonstration du
#     POC (point 30).
# ============================================================================


# ============================================================================
# 0. VERIFICATIONS, JOURNAL ET VARIABLES
# ============================================================================

# Le script installe des paquets et modifie la configuration systeme :
# il doit etre lance par root.
if [ "$EUID" -ne 0 ]; then
    echo "Ce script doit etre execute en root : su - puis bash SRV-LIN1-01.sh"
    exit 1
fi

# Journal : tout ce qui s'affiche est aussi ecrit dans le fichier de log
LOG_FILE="/var/log/SRV-LIN1-01.log"
exec > >(tee -a "${LOG_FILE}") 2>&1

# Arret immediat a la premiere erreur, avec le numero de la ligne fautive
set -e
trap 'echo ""; echo "ERREUR a la ligne ${LINENO}. Voir ${LOG_FILE}"; exit 1' ERR

# apt ne pose aucune question (installation sans intervention)
export DEBIAN_FRONTEND=noninteractive

# --- Parametres de l'infrastructure (a adapter si besoin) ---
IFACE_NAT="ens33"                 # Carte NAT (sortie Internet)
IFACE_LAN="ens34"                 # Carte interne (Host-only VMnet2)
IP_SRV01="10.10.10.11"
NETMASK="255.255.255.0"
NETWORK="10.10.10.0"
CIDR="24"
DOMAIN="lin1-labo.local"
BASE_DN="dc=lin1-labo,dc=local"   # Racine de l'annuaire (= le domaine)
ORGANISATION="LIN1-LABO"

DHCP_RANGE_START="10.10.10.100"
DHCP_RANGE_END="10.10.10.200"

# DNS de transfert : CPNV par defaut, modifiables au lancement (voir en-tete)
DNS_FORWARDER_1="${DNS_FORWARDER_1:-10.229.60.22}"
DNS_FORWARDER_2="${DNS_FORWARDER_2:-10.229.28.22}"

# Mots de passe. Guillemets simples : le $ n'est pas interprete par bash.
LDAP_ADMIN_PASSWORD='Pa$$w0rd'    # compte cn=admin de l'annuaire
USER_PASSWORD='Pa$$w0rd'          # mot de passe des 5 utilisateurs

echo "============================================================"
echo " SRV-LIN1-01 - Debut de l'installation automatisee"
echo " $(date '+%d.%m.%Y %H:%M:%S')"
echo "============================================================"

apt update
# curl sert a l'auto-controle final (test de la page LAM)
apt install -y sudo vim curl

# Nom de la machine (court + complet) pour que le serveur se reconnaisse
hostnamectl set-hostname srv-lin1-01
sed -i '/127.0.1.1/d' /etc/hosts
echo "127.0.1.1 srv-lin1-01.${DOMAIN} srv-lin1-01" >> /etc/hosts


# ============================================================================
# 1. RESEAU
# ============================================================================
# ens33 (NAT) garde le DHCP de VMware pour sortir sur Internet.
# ens34 (interne) recoit une adresse fixe : c'est l'adresse que les clients
# utiliseront comme passerelle, DNS et serveur LDAP. Pas de passerelle sur
# ens34 : la route par defaut passe par ens33.
echo ""
echo "---- [1/6] Configuration reseau ----"

cat > /etc/network/interfaces <<EOF
source /etc/network/interfaces.d/*

auto lo
iface lo inet loopback

# Carte NAT - sortie Internet (adresse donnee par VMware)
auto ${IFACE_NAT}
iface ${IFACE_NAT} inet dhcp

# Carte interne - VMnet2 Host-only (reseau LIN1-LABO)
auto ${IFACE_LAN}
iface ${IFACE_LAN} inet static
    address ${IP_SRV01}
    netmask ${NETMASK}
EOF

# Application immediate de la nouvelle configuration
systemctl restart networking || true
ip link set "${IFACE_LAN}" up || true
ifup "${IFACE_LAN}" 2>/dev/null || true

echo "Reseau configure : ${IFACE_LAN} = ${IP_SRV01}/${CIDR}"


# ============================================================================
# 2. PARTAGE DE LA CONNEXION INTERNET (ROUTAGE + NAT)
# ============================================================================
# Le reseau VMnet2 n'a pas d'acces Internet. SRV-LIN1-01 sert de passerelle :
#   - ip_forward=1 : le noyau accepte de faire passer des paquets d'une
#     carte a l'autre ;
#   - MASQUERADE   : les paquets qui sortent par ens33 prennent l'adresse
#     de SRV-LIN1-01 (traduction d'adresse, NAT) ;
#   - FORWARD      : on autorise le trafic interne -> Internet, et seulement
#     les reponses dans l'autre sens.
echo ""
echo "---- [2/6] Partage de la connexion Internet (routage + NAT) ----"

# Fichier dedie : le reglage survit au redemarrage
echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-lin1-routage.conf
sysctl --system >/dev/null

# iptables-persistent pose 2 questions a l'installation : on y repond d'avance
echo "iptables-persistent iptables-persistent/autosave_v4 boolean true" | debconf-set-selections
echo "iptables-persistent iptables-persistent/autosave_v6 boolean true" | debconf-set-selections
apt install -y iptables iptables-persistent

# "-C" verifie si la regle existe deja : relancer le script ne cree pas de
# doublons. Sinon "-A" l'ajoute.
iptables -t nat -C POSTROUTING -o "${IFACE_NAT}" -j MASQUERADE 2>/dev/null || \
    iptables -t nat -A POSTROUTING -o "${IFACE_NAT}" -j MASQUERADE
iptables -C FORWARD -i "${IFACE_LAN}" -o "${IFACE_NAT}" -j ACCEPT 2>/dev/null || \
    iptables -A FORWARD -i "${IFACE_LAN}" -o "${IFACE_NAT}" -j ACCEPT
iptables -C FORWARD -i "${IFACE_NAT}" -o "${IFACE_LAN}" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || \
    iptables -A FORWARD -i "${IFACE_NAT}" -o "${IFACE_LAN}" -m state --state RELATED,ESTABLISHED -j ACCEPT

# Sauvegarde des regles dans /etc/iptables/rules.v4 (rechargees au demarrage)
netfilter-persistent save

echo "NAT actif : ${NETWORK}/${CIDR} -> ${IFACE_NAT}"


# ============================================================================
# 3. DNS (BIND9)
# ============================================================================
# BIND9 a deux roles :
#   - serveur faisant autorite pour lin1-labo.local (noms des serveurs) et
#     pour la zone inverse 10.10.10.x (adresse -> nom) ;
#   - relais vers les DNS de transfert pour tous les autres noms (Internet).
echo ""
echo "---- [3/6] Serveur DNS (BIND9) ----"

apt install -y bind9 bind9utils dnsutils

# Options generales
#   forward only        : les noms externes sont toujours demandes aux
#                         forwarders (pas de resolution recursive directe)
#   dnssec-validation   : verification des signatures DNSSEC
#   listen-on / allow-query : le serveur ne repond qu'au reseau interne
cat > /etc/bind/named.conf.options <<EOF
options {
    directory "/var/cache/bind";

    forwarders {
        ${DNS_FORWARDER_1};
        ${DNS_FORWARDER_2};
    };
    forward only;

    dnssec-validation auto;

    listen-on { ${IP_SRV01}; 127.0.0.1; };
    allow-query { ${NETWORK}/${CIDR}; 127.0.0.1; };
    listen-on-v6 { none; };
};
EOF

# Declaration des deux zones gerees par ce serveur
cat > /etc/bind/named.conf.local <<EOF
// Zone directe : nom -> adresse
zone "${DOMAIN}" {
    type master;
    file "/etc/bind/zones/db.${DOMAIN}";
};

// Zone inverse : adresse -> nom (reseau 10.10.10.0/24)
zone "10.10.10.in-addr.arpa" {
    type master;
    file "/etc/bind/zones/db.10.10.10";
};
EOF

mkdir -p /etc/bind/zones

# Zone directe. Le "\$" protege $TTL de bash (c'est une directive BIND).
# Augmenter le Serial a chaque modification manuelle de la zone.
cat > "/etc/bind/zones/db.${DOMAIN}" <<EOF
\$TTL    604800
@       IN      SOA     srv-lin1-01.${DOMAIN}. admin.${DOMAIN}. (
                              3         ; Serial
                         604800         ; Refresh
                          86400         ; Retry
                        2419200         ; Expire
                         604800 )       ; Negative Cache TTL
;
@               IN      NS      srv-lin1-01.${DOMAIN}.
srv-lin1-01     IN      A       10.10.10.11
srv-lin1-02     IN      A       10.10.10.22
nas-lin1-01     IN      A       10.10.10.33
EOF

# Zone inverse : seul le dernier octet est ecrit (11 = 10.10.10.11)
cat > /etc/bind/zones/db.10.10.10 <<EOF
\$TTL    604800
@       IN      SOA     srv-lin1-01.${DOMAIN}. admin.${DOMAIN}. (
                              3         ; Serial
                         604800         ; Refresh
                          86400         ; Retry
                        2419200         ; Expire
                         604800 )       ; Negative Cache TTL
;
@       IN      NS      srv-lin1-01.${DOMAIN}.
11      IN      PTR     srv-lin1-01.${DOMAIN}.
22      IN      PTR     srv-lin1-02.${DOMAIN}.
33      IN      PTR     nas-lin1-01.${DOMAIN}.
EOF

# Verification de la syntaxe AVANT de redemarrer : en cas de faute, le
# script s'arrete ici avec un message clair (au lieu d'un BIND en panne).
named-checkconf
named-checkzone "${DOMAIN}" "/etc/bind/zones/db.${DOMAIN}"
named-checkzone 10.10.10.in-addr.arpa /etc/bind/zones/db.10.10.10

systemctl restart named
systemctl enable named

echo "DNS configure : zone ${DOMAIN} + zone inverse 10.10.10"


# ============================================================================
# 4. DHCP (isc-dhcp-server)
# ============================================================================
# Distribue aux clients (Linux, Windows) : une adresse de la plage, la
# passerelle (SRV-LIN1-01, pour Internet) et le DNS (SRV-LIN1-01).
# Le DHCP ecoute UNIQUEMENT sur ens34, pour ne jamais repondre sur le
# reseau NAT de VMware.
echo ""
echo "---- [4/6] Serveur DHCP ----"

# Le service echoue normalement a son premier demarrage (il n'est pas
# encore configure) : on tolere cette erreur, la configuration suit.
apt install -y isc-dhcp-server || true
systemctl stop isc-dhcp-server 2>/dev/null || true

# Carte sur laquelle le DHCP ecoute
sed -i "s/^INTERFACESv4=.*/INTERFACESv4=\"${IFACE_LAN}\"/" /etc/default/isc-dhcp-server

#   authoritative : ce serveur est LE serveur DHCP du reseau (il refuse
#                   les baux qui ne viennent pas de lui)
#   ddns-update-style none : pas de mise a jour automatique du DNS
cat > /etc/dhcp/dhcpd.conf <<EOF
option domain-name "${DOMAIN}";
option domain-name-servers ${IP_SRV01};

default-lease-time 600;
max-lease-time 7200;

ddns-update-style none;
authoritative;

subnet ${NETWORK} netmask ${NETMASK} {
    range ${DHCP_RANGE_START} ${DHCP_RANGE_END};
    option routers ${IP_SRV01};
    option domain-name-servers ${IP_SRV01};
    option domain-name "${DOMAIN}";
    option broadcast-address 10.10.10.255;
}
EOF

# Termine la configuration du paquet laissee en erreur plus haut
dpkg --configure -a
systemctl restart isc-dhcp-server
systemctl enable isc-dhcp-server

echo "DHCP configure : ${DHCP_RANGE_START} - ${DHCP_RANGE_END} sur ${IFACE_LAN}"


# ============================================================================
# 5. LDAP (OpenLDAP) : INSTALLATION ET PEUPLEMENT
# ============================================================================
# L'annuaire contient les comptes utilises par Nextcloud et par le client
# Linux. Structure creee :
#
#   dc=lin1-labo,dc=local
#   |-- cn=admin                     (administrateur de l'annuaire)
#   |-- ou=groups
#   |   |-- cn=manager      (10001)  man01, man02
#   |   |-- cn=ingenieur    (10002)  ing01, ing02
#   |   `-- cn=developpeur  (10003)  dev01
#   `-- ou=people
#       |-- uid=man01 (10001)   uid=man02 (10002)
#       |-- uid=ing01 (10003)   uid=ing02 (10004)
#       `-- uid=dev01 (10005)
echo ""
echo "---- [5/6] Annuaire LDAP : installation et peuplement ----"

# Reponses donnees d'avance aux questions d'installation de slapd :
# domaine, organisation, mot de passe admin, base MDB.
debconf-set-selections <<EOF
slapd slapd/internal/generated_adminpw password ${LDAP_ADMIN_PASSWORD}
slapd slapd/internal/adminpw password ${LDAP_ADMIN_PASSWORD}
slapd slapd/password1 password ${LDAP_ADMIN_PASSWORD}
slapd slapd/password2 password ${LDAP_ADMIN_PASSWORD}
slapd slapd/domain string ${DOMAIN}
slapd shared/organization string ${ORGANISATION}
slapd slapd/backend select MDB
slapd slapd/purge_database boolean false
slapd slapd/move_old_database boolean true
slapd slapd/no_configuration boolean false
EOF

apt install -y slapd ldap-utils
# Applique les reponses ci-dessus (cree la base dc=lin1-labo,dc=local).
# Seulement si la base n'existe pas : une reconfiguration remplacerait
# l'annuaire existant par une base vide.
if ! ldapsearch -x -LLL -b "${BASE_DN}" -s base dn >/dev/null 2>&1; then
    dpkg-reconfigure -f noninteractive slapd
fi

# Le preseed n'est pas toujours repris par dpkg-reconfigure : on force le
# mot de passe admin (stocke hache, jamais en clair dans l'annuaire).
LDAP_ADMIN_HASH=$(slappasswd -s "${LDAP_ADMIN_PASSWORD}")
cat > /tmp/admin_pw.ldif <<EOF
dn: olcDatabase={1}mdb,cn=config
changetype: modify
replace: olcRootPW
olcRootPW: ${LDAP_ADMIN_HASH}
EOF
# -Y EXTERNAL -H ldapi:/// : connexion locale en tant que root du systeme,
# seule facon de modifier la configuration (cn=config) sans mot de passe
ldapmodify -Y EXTERNAL -H ldapi:/// -f /tmp/admin_pw.ldif
rm -f /tmp/admin_pw.ldif

# Peuplement seulement si l'annuaire est vide (le script peut etre relance)
if ldapsearch -x -LLL -b "ou=people,${BASE_DN}" -s base dn >/dev/null 2>&1; then
    echo "Annuaire deja peuple : peuplement ignore."
else

    # --- Unites d'organisation (OU) : une pour les groupes, une pour les personnes ---
    cat > /tmp/base.ldif <<EOF
dn: ou=groups,${BASE_DN}
objectClass: organizationalUnit
ou: groups

dn: ou=people,${BASE_DN}
objectClass: organizationalUnit
ou: people
EOF

    # --- Groupes (posixGroup) ---
    # gidNumber fixes a partir de 10001 : hors de la plage des comptes
    # locaux Debian (1000+), donc aucun conflit sur les clients Linux.
    # memberUid liste les membres : c'est l'attribut que Nextcloud lit pour
    # savoir qui est dans quel groupe (ldapGroupMemberAssocAttr=memberUid).
    cat > /tmp/groups.ldif <<EOF
dn: cn=manager,ou=groups,${BASE_DN}
objectClass: posixGroup
cn: manager
gidNumber: 10001
memberUid: man01
memberUid: man02

dn: cn=ingenieur,ou=groups,${BASE_DN}
objectClass: posixGroup
cn: ingenieur
gidNumber: 10002
memberUid: ing01
memberUid: ing02

dn: cn=developpeur,ou=groups,${BASE_DN}
objectClass: posixGroup
cn: developpeur
gidNumber: 10003
memberUid: dev01
EOF

    # --- Utilisateurs ---
    # Une ligne par utilisateur : uid:prenom:nom:uidNumber:gidNumber
    # (gidNumber = groupe principal). Pour ajouter un utilisateur, ajouter
    # une ligne ici ET son memberUid dans le groupe ci-dessus.
    USERS="
man01:Manager:Un:10001:10001
man02:Manager:Deux:10002:10001
ing01:Ingenieur:Un:10003:10002
ing02:Ingenieur:Deux:10004:10002
dev01:Developpeur:Un:10005:10003
"

    # Chaque utilisateur est a la fois :
    #   inetOrgPerson : personne (nom, prenom, nom affiche) -> Nextcloud, LAM
    #   posixAccount  : compte Unix (uid/gid, home, shell)  -> client Linux
    #   shadowAccount : informations d'expiration du mot de passe
    # userPassword {CRYPT}x = compte verrouille, le vrai mot de passe est
    # pose juste apres avec ldappasswd (hache par le serveur).
    : > /tmp/users.ldif
    for ENTRY in ${USERS}; do
        IFS=':' read -r U_ID U_GIVEN U_SN U_UIDNUM U_GIDNUM <<< "${ENTRY}"
        cat >> /tmp/users.ldif <<EOF
dn: uid=${U_ID},ou=people,${BASE_DN}
objectClass: inetOrgPerson
objectClass: posixAccount
objectClass: shadowAccount
uid: ${U_ID}
cn: ${U_GIVEN} ${U_SN}
sn: ${U_SN}
givenName: ${U_GIVEN}
displayName: ${U_ID}
uidNumber: ${U_UIDNUM}
gidNumber: ${U_GIDNUM}
homeDirectory: /home/${U_ID}
loginShell: /bin/bash
userPassword: {CRYPT}x

EOF
    done

    # Import dans l'ordre : les OU doivent exister avant leur contenu
    ldapadd -x -D "cn=admin,${BASE_DN}" -w "${LDAP_ADMIN_PASSWORD}" -f /tmp/base.ldif
    ldapadd -x -D "cn=admin,${BASE_DN}" -w "${LDAP_ADMIN_PASSWORD}" -f /tmp/groups.ldif
    ldapadd -x -D "cn=admin,${BASE_DN}" -w "${LDAP_ADMIN_PASSWORD}" -f /tmp/users.ldif

    # Mot de passe de chaque utilisateur
    for ENTRY in ${USERS}; do
        U_ID="${ENTRY%%:*}"
        ldappasswd -x -D "cn=admin,${BASE_DN}" -w "${LDAP_ADMIN_PASSWORD}" \
            -s "${USER_PASSWORD}" "uid=${U_ID},ou=people,${BASE_DN}"
    done

    # Les fichiers LDIF contiennent la structure de l'annuaire : on nettoie
    rm -f /tmp/base.ldif /tmp/groups.ldif /tmp/users.ldif

    echo "LDAP peuple : 2 OU, 3 groupes, 5 utilisateurs"
fi


# ============================================================================
# 6. LAM (LDAP Account Manager)
# ============================================================================
# Interface web pour gerer l'annuaire sans ecrire de LDIF :
# http://10.10.10.11/lam  (connexion avec cn=admin)
echo ""
echo "---- [6/6] LAM (LDAP Account Manager) ----"

apt install -y apache2 ldap-account-manager
systemctl enable --now apache2

# LAM est livre avec un profil d'exemple (dc=my-domain,dc=com). On le
# remplace par notre annuaire : equivalent de la configuration faite a la
# main dans "LAM configuration > Edit server profiles".
LAM_CONF="/var/lib/ldap-account-manager/config/lam.conf"
if [ -f "${LAM_CONF}" ]; then
    sed -i \
        -e "s/dc=my-domain,dc=com/${BASE_DN}/g" \
        -e "s/dc=yourdomain,dc=org/${BASE_DN}/g" \
        -e "s/cn=Manager,/cn=admin,/g" \
        -e "s/ou=People,/ou=people,/g" \
        -e "s/ou=group,/ou=groups,/g" \
        "${LAM_CONF}"
    echo "Profil LAM adapte : ${BASE_DN}"
else
    echo "ATTENTION : ${LAM_CONF} introuvable, configurer le profil LAM a la main"
    echo "(http://${IP_SRV01}/lam > LAM configuration, mot de passe 'lam')."
fi


# ============================================================================
# RESOLVEUR DNS LOCAL
# ============================================================================
# Fait en dernier, une fois BIND9 fonctionnel : le serveur utilise son
# propre DNS au lieu de celui du NAT VMware. "supersede" empeche le DHCP
# de ens33 de reecrire resolv.conf au prochain renouvellement.
if ! grep -q "LIN1-LABO" /etc/dhcp/dhclient.conf; then
    cat >> /etc/dhcp/dhclient.conf <<EOF

# LIN1-LABO : utiliser le DNS local
supersede domain-name-servers ${IP_SRV01};
supersede domain-name "${DOMAIN}";
EOF
fi

cat > /etc/resolv.conf <<EOF
domain ${DOMAIN}
search ${DOMAIN}
nameserver ${IP_SRV01}
EOF


# ============================================================================
# AUTO-CONTROLE
# ============================================================================
# Chaque service est teste apres l'installation. Un ECHEC n'arrete pas le
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

echo ""
echo "---- Auto-controle ----"
controle "Adresse ${IP_SRV01} sur ${IFACE_LAN}" \
    "ip -4 addr show ${IFACE_LAN} | grep -q ' ${IP_SRV01}/'"
controle "Routage IPv4 active" \
    "[ \"\$(cat /proc/sys/net/ipv4/ip_forward)\" = 1 ]"
controle "Regle NAT (MASQUERADE) sur ${IFACE_NAT}" \
    "iptables -t nat -C POSTROUTING -o ${IFACE_NAT} -j MASQUERADE"
controle "Service DNS (named) actif" \
    "systemctl is-active --quiet named"
controle "DNS : srv-lin1-02.${DOMAIN} -> 10.10.10.22" \
    "dig +short @127.0.0.1 srv-lin1-02.${DOMAIN} | grep -qx 10.10.10.22"
controle "DNS inverse : 10.10.10.33 -> nas-lin1-01" \
    "dig +short @127.0.0.1 -x 10.10.10.33 | grep -q nas-lin1-01"
controle "DNS externe : www.google.com (via les forwarders)" \
    "dig +short @127.0.0.1 www.google.com | grep -q ."
controle "Service DHCP actif" \
    "systemctl is-active --quiet isc-dhcp-server"
controle "Service LDAP (slapd) actif" \
    "systemctl is-active --quiet slapd"
controle "LDAP : 3 groupes presents" \
    "[ \"\$(ldapsearch -x -LLL -b ou=groups,${BASE_DN} '(objectClass=posixGroup)' cn | grep -c '^cn:')\" -ge 3 ]"
controle "LDAP : 5 utilisateurs presents" \
    "[ \"\$(ldapsearch -x -LLL -b ou=people,${BASE_DN} '(objectClass=posixAccount)' uid | grep -c '^uid:')\" -ge 5 ]"
controle "LDAP : connexion de dev01 avec son mot de passe" \
    "ldapwhoami -x -D uid=dev01,ou=people,${BASE_DN} -w '${USER_PASSWORD}'"
controle "LAM : page web http://${IP_SRV01}/lam" \
    "curl -s -o /dev/null -w '%{http_code}' -L http://127.0.0.1/lam/ | grep -q 200"


# ============================================================================
# FIN
# ============================================================================
echo ""
echo "============================================================"
if [ "${ECHECS}" -eq 0 ]; then
    echo " SRV-LIN1-01 - Installation terminee : tous les controles OK"
else
    echo " SRV-LIN1-01 - Installation terminee : ${ECHECS} controle(s) en ECHEC"
fi
echo "============================================================"
echo " Reseau : ${IFACE_LAN} = ${IP_SRV01}/${CIDR}, NAT vers ${IFACE_NAT}"
echo " DNS    : zone ${DOMAIN} (forwarders ${DNS_FORWARDER_1}, ${DNS_FORWARDER_2})"
echo " DHCP   : ${DHCP_RANGE_START} - ${DHCP_RANGE_END}"
echo " LDAP   : ${BASE_DN} (cn=admin)"
echo " LAM    : http://${IP_SRV01}/lam"
echo " Journal: ${LOG_FILE}"
echo ""
echo " A faire a la main :"
echo "   - Copier la cle publique SSH dans ~/.ssh/authorized_keys,"
echo "     puis PasswordAuthentication no dans /etc/ssh/sshd_config"
echo "============================================================"
