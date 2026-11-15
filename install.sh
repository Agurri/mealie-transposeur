#!/usr/bin/env bash
# =============================================================================
#  Transposeur de recettes → Mealie — conteneur LXC pour Proxmox VE
#  À lancer sur l'HÔTE Proxmox (shell du nœud), en root :
#
#      bash -c "$(curl -fsSL https://raw.githubusercontent.com/Agurri/mealie-transposeur/main/install.sh)"
#
#  Premier lancement : crée le conteneur. Lancements suivants : met la page à jour depuis GitHub.
#  Avec des options, téléchargez d'abord le script :
#
#      curl -fsSLO https://raw.githubusercontent.com/Agurri/mealie-transposeur/main/install.sh
#      bash install.sh status                      conteneur, version installée, état du relais
#      bash install.sh update --mealie HÔTE:PORT   change l'adresse de Mealie
#      bash install.sh update --os                 met aussi à jour les paquets du conteneur
#      bash install.sh install --ctid 123 --yes    installation sans question
#
#  Options : --ctid N · --mealie HÔTE:PORT · --html FICHIER_OU_URL (autre version de la page) · --os · --yes
#
#  Dans le conteneur, la commande « update » récupère aussi la dernière page depuis GitHub.
#
#  Le conteneur (Debian + Caddy) sert la page et relaie /api/ vers Mealie :
#  même origine pour le navigateur, donc aucun blocage CORS.
# =============================================================================
set -Eeuo pipefail

APP="Transposeur Mealie"
REPO="${REPO:-Agurri/mealie-transposeur}"
BRANCH="${BRANCH:-main}"
RAW="https://raw.githubusercontent.com/$REPO/$BRANCH"
VERSION="$(curl -fsSL "$RAW/VERSION" 2>/dev/null | head -1 | tr -d '[:space:]')"; VERSION="${VERSION:-inconnue}"
TAG="transposeur"
WEBROOT="/var/www/transposeur"
SELF="${BASH_SOURCE[0]:-}"; [[ -f "$SELF" ]] && SELF="$(readlink -f "$SELF")" || SELF=""
NAME="$([[ -n "$SELF" ]] && basename "$SELF" || echo install.sh)"

G=$'\e[32m'; R=$'\e[31m'; Y=$'\e[33m'; B=$'\e[1m'; N=$'\e[0m'
info(){ echo -e " ${Y}…${N} $*"; }
ok(){   echo -e " ${G}✔${N} $*"; }
warn(){ echo -e " ${Y}!${N} $*"; }
die(){  echo -e " ${R}✖ $*${N}" >&2; exit 1; }
trap 'die "Erreur à la ligne $LINENO (commande : $BASH_COMMAND)"' ERR

ACTION=""; CTID="${CTID:-}"; MEALIE="${MEALIE:-}"; HTML_SRC=""; DO_OS=0; YES=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    install|update|status) ACTION="$1";;
    --ctid)   CTID="${2:?}"; shift;;
    --mealie) MEALIE="${2:?}"; shift;;
    --html)   HTML_SRC="${2:?}"; shift;;
    --os)     DO_OS=1;;
    --yes|-y) YES=1;;
    -h|--help) if [[ -n "$SELF" ]]; then sed -n '2,24p' "$SELF" | sed 's/^# \{0,2\}//'; else echo "Voir https://github.com/$REPO"; fi; exit 0;;
    *) die "Option inconnue : $1 (voir --help)";;
  esac
  shift
done

[[ $EUID -eq 0 ]] || die "À lancer en root sur l'hôte Proxmox."
command -v pct >/dev/null || die "Commande « pct » introuvable : ce script se lance sur l'hôte Proxmox, pas dans un conteneur."

# --- question avec valeur par défaut -----------------------------------------
ask(){ # ask "Question" "défaut"
  local a=""
  if [[ $YES -eq 1 || ! -r /dev/tty ]]; then echo "$2"; return; fi
  read -r -p " ${B}$1${N} [$2] : " a </dev/tty || true
  echo "${a:-$2}"
}

# --- la page : incluse dans ce script, ou fournie par --html -------------------
fetch_html(){ # fetch_html destination
  if [[ -z "$HTML_SRC" ]]; then
    curl -fsSL "$RAW/index.html" -o "$1" || die "Téléchargement impossible depuis $RAW (réseau ? dépôt privé ?)."
  elif [[ "$HTML_SRC" =~ ^https?:// ]]; then
    curl -fsSL "$HTML_SRC" -o "$1"
  else
    [[ -f "$HTML_SRC" ]] || die "Fichier introuvable : $HTML_SRC"
    cp "$HTML_SRC" "$1"
  fi
  grep -q "Transposeur de recettes" "$1" || die "Le fichier obtenu n'est pas la page du transposeur."
}
page_version(){ [[ -z "$HTML_SRC" ]] && echo "$VERSION" || echo "perso-$(date +%Y.%m.%d-%H%M)"; }

find_ct(){
  local id
  for id in $(pct list | awk 'NR>1{print $1}'); do
    if pct config "$id" 2>/dev/null | grep -qE "^tags:.*(^|[ ;,:])$TAG($|[ ;,])"; then echo "$id"; return 0; fi
  done
  return 1
}
ct_ip(){ pct exec "$1" -- hostname -I 2>/dev/null | awk '{print $1}'; }

detect_mealie(){
  local id name ip
  while read -r id name; do
    [[ "${name,,}" == *mealie* ]] || continue
    ip="$(ct_ip "$id" || true)"
    [[ -n "$ip" ]] && { echo "$ip:9000"; return 0; }
  done < <(pct list | awk 'NR>1 && $2=="running"{print $1, $NF}')
  return 1
}

write_caddyfile(){ # write_caddyfile ctid mealie
  local t up extra=""
  t="$(mktemp)"; up="$2"
  [[ "$up" =~ ^https:// ]] && extra=$' {\n\t\t\theader_up Host {upstream_hostport}\n\t\t}'
  cat > "$t" <<CADDY
# Généré par install.sh — relancez le script avec --mealie pour changer la cible
:80 {
	encode gzip
	handle /api/* {
		reverse_proxy ${up}${extra}
	}
	handle {
		root * ${WEBROOT}
		header Cache-Control "no-cache"
		file_server
	}
}
CADDY
  pct push "$1" "$t" /etc/caddy/Caddyfile --perms 644
  printf 'MEALIE=%s\nRAW=%s\n' "$up" "$RAW" > "$t"; pct push "$1" "$t" /etc/transposeur.conf --perms 644
  cat > "$t" <<'UPD'
#!/bin/sh
# Met à jour la page du transposeur depuis GitHub (à lancer dans le conteneur)
. /etc/transposeur.conf
W=/var/www/transposeur; T="$(mktemp)"
curl -fsSL "$RAW/index.html" -o "$T" && grep -q "Transposeur de recettes" "$T" || { echo "Téléchargement impossible depuis $RAW"; rm -f "$T"; exit 1; }
OLD="$(cat "$W/VERSION" 2>/dev/null || echo inconnue)"; NEW="$(curl -fsSL "$RAW/VERSION" 2>/dev/null | head -1 | tr -d '[:space:]')"
install -m 644 "$T" "$W/index.html"; echo "${NEW:-inconnue}" > "$W/VERSION"; rm -f "$T"
echo "Transposeur : $OLD -> ${NEW:-inconnue}"
UPD
  pct push "$1" "$t" /usr/local/bin/update --perms 755
  rm -f "$t"
  pct exec "$1" -- systemctl enable caddy >/dev/null 2>&1 || true
  pct exec "$1" -- systemctl restart caddy
}

deploy_page(){ # deploy_page ctid
  local t v
  t="$(mktemp)"; fetch_html "$t"
  pct exec "$1" -- mkdir -p "$WEBROOT"
  pct push "$1" "$t" "$WEBROOT/index.html" --perms 644
  v="$(page_version)"; echo "$v" > "$t"
  pct push "$1" "$t" "$WEBROOT/VERSION" --perms 644
  rm -f "$t"
}

check(){ # check ctid
  local ip; ip="$(ct_ip "$1" || true)"
  [[ -n "$ip" ]] || { warn "Adresse IP du conteneur introuvable pour l'instant."; return 0; }
  if curl -fsS -m 8 "http://$ip/" 2>/dev/null | grep -q "Transposeur de recettes"; then ok "Page servie : ${B}http://$ip${N}"
  else warn "La page ne répond pas encore sur http://$ip (journal : pct exec $1 -- journalctl -u caddy -n 30)"; fi
  if curl -fsS -m 8 "http://$ip/api/app/about" 2>/dev/null | grep -q '"version"'; then ok "Relais vers Mealie fonctionnel (/api)"
  else warn "Mealie ne répond pas à travers le relais. Vérifiez l'adresse : bash $NAME update --mealie HÔTE:PORT"; fi
}

do_install(){
  echo -e "\n ${B}$APP — installation (version $VERSION)${N}\n"
  local next stor tstor tmpl host bridge ip gw net cur
  next="$(pvesh get /cluster/nextid)"
  CTID="$(ask "Numéro du conteneur" "${CTID:-$next}")"
  pct status "$CTID" >/dev/null 2>&1 && die "Le conteneur $CTID existe déjà."
  host="$(ask "Nom du conteneur" "transposeur")"
  stor="$(pvesm status -content rootdir | awk 'NR>1{print $1}' | grep -x local-lvm || pvesm status -content rootdir | awk 'NR>1{print $1}' | head -1)"
  [[ -n "$stor" ]] || die "Aucun stockage acceptant des conteneurs."
  stor="$(ask "Stockage du disque (2 Go)" "$stor")"
  bridge="$(ask "Pont réseau" "vmbr0")"
  ip="$(ask "Adresse IP (dhcp, ou p. ex. 192.168.1.60/24)" "dhcp")"
  net="ip=dhcp"
  if [[ "$ip" != "dhcp" ]]; then gw="$(ask "Passerelle" "$(ip route | awk '/^default/{print $3; exit}')")"; net="ip=$ip,gw=$gw"; fi
  if [[ -z "$MEALIE" ]]; then
    cur="$(detect_mealie || true)"
    [[ -n "$cur" ]] && info "Conteneur Mealie repéré : $cur"
    MEALIE="$(ask "Adresse de Mealie (hôte:port)" "${cur:-192.168.1.50:9000}")"
  fi
  MEALIE="${MEALIE#http://}"; MEALIE="${MEALIE%/}"

  info "Recherche du modèle Debian…"
  tstor="$(pvesm status -content vztmpl | awk 'NR>1{print $1}' | head -1)"
  [[ -n "$tstor" ]] || die "Aucun stockage acceptant des modèles de conteneurs."
  pveam update >/dev/null 2>&1 || warn "Liste des modèles non rafraîchie."
  tmpl="$(pveam available --section system | awk '{print $2}' | grep -E '^debian-1[0-9]-standard' | sort -V | tail -1)"
  [[ -n "$tmpl" ]] || die "Aucun modèle Debian disponible."
  pveam list "$tstor" | grep -q "$tmpl" || { info "Téléchargement de $tmpl…"; pveam download "$tstor" "$tmpl" >/dev/null; }
  ok "Modèle : $tmpl"

  info "Création du conteneur $CTID…"
  pct create "$CTID" "$tstor:vztmpl/$tmpl" \
    --hostname "$host" --cores 1 --memory 512 --swap 512 --rootfs "$stor:2" \
    --net0 "name=eth0,bridge=$bridge,$net" --unprivileged 1 --features nesting=1 \
    --onboot 1 --tags "$TAG" \
    --description "$APP — page servie par Caddy, /api relayé vers Mealie ($MEALIE). Mise à jour : relancer install.sh sur l'hôte." >/dev/null
  pct start "$CTID"
  ok "Conteneur créé et démarré"

  info "Attente du réseau…"
  local i
  for i in $(seq 1 30); do pct exec "$CTID" -- getent hosts deb.debian.org >/dev/null 2>&1 && break; sleep 2; done
  pct exec "$CTID" -- getent hosts deb.debian.org >/dev/null 2>&1 || die "Le conteneur n'a pas d'accès réseau (DHCP ? DNS ?)."

  info "Installation de Caddy…"
  pct exec "$CTID" -- bash -c "export DEBIAN_FRONTEND=noninteractive; apt-get update -qq && apt-get install -y -qq caddy curl ca-certificates >/dev/null"
  ok "Caddy installé"

  deploy_page "$CTID"; ok "Page déployée (version $(page_version))"
  write_caddyfile "$CTID" "$MEALIE"; ok "Relais /api → $MEALIE configuré"
  sleep 2; check "$CTID"
  echo -e "\n ${G}Terminé.${N} Ouvrez l'adresse ci-dessus, entrez votre jeton API Mealie, et c'est prêt."
  echo -e " Mise à jour plus tard : relancez la même commande sur l'hôte, ou tapez ${B}update${N} dans le conteneur.\n"
}

do_update(){
  local old new
  [[ -n "$CTID" ]] || CTID="$(find_ct)" || die "Aucun conteneur étiqueté « $TAG ». Précisez --ctid N, ou lancez « install »."
  pct status "$CTID" >/dev/null 2>&1 || die "Conteneur $CTID introuvable."
  echo -e "\n ${B}$APP — mise à jour du conteneur $CTID${N}\n"
  pct status "$CTID" | grep -q running || { info "Démarrage du conteneur…"; pct start "$CTID"; sleep 4; }
  old="$(pct exec "$CTID" -- cat "$WEBROOT/VERSION" 2>/dev/null || echo "inconnue")"
  deploy_page "$CTID"; new="$(page_version)"
  if [[ "$old" == "$new" ]]; then ok "Page réinstallée (version $new, inchangée)"; else ok "Page mise à jour : $old → $new"; fi
  if [[ -n "$MEALIE" ]]; then MEALIE="${MEALIE#http://}"; MEALIE="${MEALIE%/}"; write_caddyfile "$CTID" "$MEALIE"; ok "Relais /api → $MEALIE reconfiguré"; fi
  if [[ $DO_OS -eq 1 ]]; then
    info "Mise à jour des paquets du conteneur…"
    pct exec "$CTID" -- bash -c "export DEBIAN_FRONTEND=noninteractive; apt-get update -qq && apt-get -y -qq dist-upgrade >/dev/null && apt-get -y -qq autoremove >/dev/null"
    ok "Paquets à jour"
  fi
  check "$CTID"; echo
}

do_status(){
  [[ -n "$CTID" ]] || CTID="$(find_ct)" || die "Aucun conteneur étiqueté « $TAG »."
  echo -e "\n ${B}$APP${N}"
  echo " Conteneur        : $CTID ($(pct status "$CTID" | awk '{print $2}'))"
  echo " Version installée : $(pct exec "$CTID" -- cat "$WEBROOT/VERSION" 2>/dev/null || echo "?")"
  echo " Version du script : $VERSION"
  echo " Cible Mealie      : $(pct exec "$CTID" -- sed -n 's/^MEALIE=//p' /etc/transposeur.conf 2>/dev/null || echo "?")"
  check "$CTID"; echo
}

if [[ -z "$ACTION" ]]; then
  if [[ -n "$CTID" ]] && pct status "$CTID" >/dev/null 2>&1; then ACTION=update
  elif find_ct >/dev/null; then ACTION=update
  else ACTION=install; fi
fi
case "$ACTION" in install) do_install;; update) do_update;; status) do_status;; esac
exit 0
