#!/usr/bin/env bash
# =============================================================================
#  Transposeur de recettes → Mealie — conteneur LXC pour Proxmox VE
#  À lancer sur l'HÔTE Proxmox (shell du nœud), en root :
#
#      bash -c "$(curl -fsSL https://raw.githubusercontent.com/Agurri/mealie-transposeur/main/install.sh)"
#
#  Premier lancement : crée le conteneur. Lancements suivants : met tout à jour depuis GitHub
#  (page, bibliothèques, relais web, configuration de Caddy).
#  Avec des options, téléchargez d'abord le script :
#
#      curl -fsSLO https://raw.githubusercontent.com/Agurri/mealie-transposeur/main/install.sh
#      bash install.sh status                      conteneur, version installée, état des relais
#      bash install.sh update --mealie HÔTE:PORT   change l'adresse de Mealie
#      bash install.sh update --https              ajoute l'accès chiffré https://ADRESSE (certificat interne)
#      bash install.sh update --os                 met aussi à jour les paquets du conteneur
#      bash install.sh install --ctid 123 --yes    installation sans question
#
#  Options : --ctid N · --mealie HÔTE:PORT · --html FICHIER_OU_URL (autre version de la page)
#            --https · --no-https · --os · --yes
#
#  Dans le conteneur, la commande « update » récupère aussi la dernière page, les bibliothèques
#  et le relais web depuis GitHub.
#
#  Le conteneur (Debian + Caddy) sert la page et relaie /api/ vers Mealie (même origine pour le
#  navigateur, donc aucun blocage CORS) et /web vers les sites publics de recettes.
# =============================================================================
set -Eeuo pipefail

APP="Transposeur Mealie"
REPO="${REPO:-Agurri/mealie-transposeur}"
BRANCH="${BRANCH:-main}"
RAW="https://raw.githubusercontent.com/$REPO/$BRANCH"
TAG="transposeur"
WEBROOT="/var/www/transposeur"
WEBPORT=8377
SELF="${BASH_SOURCE[0]:-}"; [[ -f "$SELF" ]] && SELF="$(readlink -f "$SELF")" || SELF=""
NAME="$([[ -n "$SELF" ]] && basename "$SELF" || echo install.sh)"

G=$'\e[32m'; R=$'\e[31m'; Y=$'\e[33m'; B=$'\e[1m'; N=$'\e[0m'
info(){ echo -e " ${Y}…${N} $*"; }
ok(){   echo -e " ${G}✔${N} $*"; }
warn(){ echo -e " ${Y}!${N} $*"; }
die(){  echo -e " ${R}✖ $*${N}" >&2; exit 1; }
trap 'die "Erreur à la ligne $LINENO (commande : $BASH_COMMAND)"' ERR
PAGE=""; VERSION="inconnue"
trap 'if [[ -n "$PAGE" ]]; then rm -f "$PAGE"; fi' EXIT

ACTION=""; CTID="${CTID:-}"; MEALIE="${MEALIE:-}"; HTML_SRC=""; DO_OS=0; YES=0; HTTPS=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    install|update|status) ACTION="$1";;
    --ctid)   CTID="${2:?}"; shift;;
    --mealie) MEALIE="${2:?}"; shift;;
    --html)   HTML_SRC="${2:?}"; shift;;
    --https)    HTTPS=1;;
    --no-https) HTTPS=0;;
    --os)     DO_OS=1;;
    --yes|-y) YES=1;;
    -h|--help) if [[ -n "$SELF" ]]; then sed -n '2,27p' "$SELF" | sed 's/^# \{0,2\}//'; else echo "Voir https://github.com/$REPO"; fi; exit 0;;
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

# --- la page : téléchargée depuis le dépôt, ou fournie par --html --------------
# Sa version est inscrite dans la page elle-même : page et numéro de version ne peuvent pas diverger.
page_ver(){ sed -n 's/.*<meta name="transposeur-version" content="\([^"]*\)".*/\1/p' "$1" | head -1; }
fetch_html(){ # fetch_html destination
  if [[ -z "$HTML_SRC" ]]; then
    curl -fsSL "$RAW/index.html" -o "$1" || die "Téléchargement impossible depuis $RAW (réseau ? dépôt privé ?)."
  elif [[ "$HTML_SRC" =~ ^https?:// ]]; then
    curl -fsSL "$HTML_SRC" -o "$1" || die "Téléchargement impossible : $HTML_SRC"
  else
    [[ -f "$HTML_SRC" ]] || die "Fichier introuvable : $HTML_SRC"
    cp "$HTML_SRC" "$1"
  fi
  grep -q "Transposeur de recettes" "$1" || die "Le fichier obtenu n'est pas la page du transposeur."
  tail -c 200 "$1" | grep -q '</html>' || die "La page téléchargée est incomplète (téléchargement interrompu ?). Réessayez."
}
get_page(){
  PAGE="$(mktemp)"; fetch_html "$PAGE"
  VERSION="$(page_ver "$PAGE")"; VERSION="${VERSION:-inconnue}"
  [[ -z "$HTML_SRC" ]] || VERSION="$VERSION (page fournie par --html)"
}

find_ct(){
  local id
  for id in $(pct list | awk 'NR>1{print $1}'); do
    if pct config "$id" 2>/dev/null | grep -E "^tags:.*(^|[ ;,:])$TAG($|[ ;,])" >/dev/null; then echo "$id"; return 0; fi
  done
  return 1
}
ct_ip(){ pct exec "$1" -- hostname -I 2>/dev/null | awk '{print $1}'; }
ct_conf(){ # ct_conf ctid CLÉ → valeur enregistrée dans le conteneur
  pct exec "$1" -- sed -n "s/^$2=//p" /etc/transposeur.conf 2>/dev/null | head -1 | tr -d "'\"" || true
}
push(){ # push ctid fichier_local destination droits
  pct push "$1" "$2" "$3" --perms "$4"
}

detect_mealie(){
  local id name ip
  while read -r id name; do
    [[ "${name,,}" == *mealie* ]] || continue
    ip="$(ct_ip "$id" || true)"
    [[ -n "$ip" ]] && { echo "$ip:9000"; return 0; }
  done < <(pct list | awk 'NR>1 && $2=="running"{print $1, $NF}')
  return 1
}

# --- configuration du conteneur : Caddy, relais web, bibliothèques, commande « update » ---
setup_ct(){ # setup_ct ctid mealie https(0|1)
  local ct="$1" up="$2" https="$3" t extra="" ip host sites=""
  t="$(mktemp)"

  # 1. relais web (lecture des sites de recettes) : petit service Python, joint par Caddy sur 127.0.0.1
  if ! pct exec "$ct" -- sh -c 'command -v python3 >/dev/null 2>&1'; then
    info "Installation de Python (relais web)…"
    pct exec "$ct" -- bash -c "export DEBIAN_FRONTEND=noninteractive; apt-get update -qq && apt-get install -y -qq python3 >/dev/null" \
      || warn "Python n'a pas pu être installé : la recherche des recettes sur le web ne fonctionnera pas."
  fi
  pct exec "$ct" -- mkdir -p /usr/local/lib/transposeur "$WEBROOT"
  if curl -fsSL "$RAW/webrelay.py" -o "$t" && grep -q "Relais web du transposeur" "$t"; then
    push "$ct" "$t" /usr/local/lib/transposeur/webrelay.py 644
    cat > "$t" <<UNIT
[Unit]
Description=Relais web du transposeur de recettes
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/bin/python3 /usr/local/lib/transposeur/webrelay.py
Environment=TRANSPOSEUR_WEB_PORT=$WEBPORT
User=www-data
Group=www-data
NoNewPrivileges=yes
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT
    push "$ct" "$t" /etc/systemd/system/transposeur-web.service 644
    pct exec "$ct" -- systemctl daemon-reload
    pct exec "$ct" -- systemctl enable transposeur-web >/dev/null 2>&1 || true
    pct exec "$ct" -- systemctl restart transposeur-web || warn "Le relais web n'a pas démarré (journal : pct exec $ct -- journalctl -u transposeur-web -n 30)."
  else
    warn "Relais web non téléchargé depuis $RAW : la recherche des recettes sur le web ne fonctionnera pas."
  fi

  # 2. Caddy
  [[ "$up" =~ ^https:// ]] && extra=$' {\n\t\t\theader_up Host {upstream_hostport}\n\t\t}'
  if [[ "$https" == 1 ]]; then
    ip="$(ct_ip "$ct" || true)"; host="$(pct exec "$ct" -- hostname 2>/dev/null || true)"
    [[ -n "$ip" ]] && sites="https://$ip"
    [[ -n "$host" ]] && sites="${sites:+$sites, }https://$host"
    [[ -n "$sites" ]] || { warn "Adresse du conteneur inconnue : accès HTTPS non configuré."; https=0; }
  fi
  {
    echo "# Généré par install.sh — relancez-le avec --mealie pour changer la cible, --https / --no-https pour l'accès chiffré"
    if [[ "$https" == 1 ]]; then printf '{\n\tauto_https disable_redirects\n}\n'; fi
    cat <<CADDY
(transposeur) {
	encode gzip
	handle /api/* {
		reverse_proxy ${up}${extra}
	}
	handle /web {
		reverse_proxy 127.0.0.1:${WEBPORT}
	}
	handle {
		root * ${WEBROOT}
		header Cache-Control "no-cache"
		file_server
	}
}
:80 {
	import transposeur
}
CADDY
    if [[ "$https" == 1 ]]; then printf '%s {\n\ttls internal\n\timport transposeur\n}\n' "$sites"; fi
  } > "$t"
  push "$ct" "$t" /etc/caddy/Caddyfile 644
  printf "MEALIE='%s'\nRAW='%s'\nHTTPS='%s'\n" "$up" "$RAW" "$https" > "$t"; push "$ct" "$t" /etc/transposeur.conf 644

  # 3. bibliothèques PDF et OCR : copiées dans le conteneur et vérifiées (la page s'en sert au lieu du CDN)
  cat > "$t" <<'LIBS'
#!/bin/sh
# Télécharge dans le conteneur les bibliothèques listées dans libs.txt (dépôt GitHub) et vérifie leur empreinte.
. /etc/transposeur.conf
L=/var/www/transposeur/lib; mkdir -p "$L"; cd "$L" || exit 1
T="$(mktemp)"; trap 'rm -f "$T"' EXIT
curl -fsSL "$RAW/libs.txt" -o "$T" || { echo "Liste des bibliothèques introuvable sur $RAW"; exit 1; }
good(){ [ -f "$1" ] && echo "$2  $1" | sha256sum -c - >/dev/null 2>&1; }
ok=1; meta=""; keep="ok.json"
while read -r name url sum; do
  case "$name" in ''|'#'*) continue;; '@') meta="$url${sum:+ $sum}"; continue;; esac
  case "$name" in */*|.*) continue;; esac
  keep="$keep $name"
  good "$name" "$sum" && continue
  if curl -fsSL "$url" -o "$name.part" && good "$name.part" "$sum"; then mv "$name.part" "$name"
  else rm -f "$name.part"; echo "échec ou empreinte incorrecte : $name"; ok=0; fi
done < "$T"
for f in *; do case " $keep " in *" $f "*) ;; *) rm -f "$f";; esac; done
if [ "$ok" = 1 ] && [ -n "$meta" ]; then printf '%s\n' "$meta" > ok.json; chmod 644 ./*; echo "Bibliothèques à jour"
else rm -f ok.json; echo "Bibliothèques incomplètes : la page utilisera le CDN"; exit 1; fi
LIBS
  push "$ct" "$t" /usr/local/bin/transposeur-libs 755

  # 4. commande « update » du conteneur
  cat > "$t" <<'UPD'
#!/bin/sh
# Met à jour le transposeur depuis GitHub : page, bibliothèques, relais web (à lancer dans le conteneur).
# La configuration de Caddy, elle, se met à jour en relançant install.sh sur l'hôte Proxmox.
. /etc/transposeur.conf
W=/var/www/transposeur; T="$(mktemp)"; trap 'rm -f "$T"' EXIT
ver(){ sed -n 's/.*<meta name="transposeur-version" content="\([^"]*\)".*/\1/p' "$1" | head -1; }
curl -fsSL "$RAW/index.html" -o "$T" && grep -q "Transposeur de recettes" "$T" && tail -c 200 "$T" | grep -q '</html>' \
  || { echo "Téléchargement impossible ou incomplet depuis $RAW"; exit 1; }
OLD="$(cat "$W/VERSION" 2>/dev/null || echo inconnue)"; NEW="$(ver "$T")"
install -m 644 "$T" "$W/index.html"; echo "${NEW:-inconnue}" > "$W/VERSION"
echo "Transposeur : $OLD -> ${NEW:-inconnue}"
/usr/local/bin/transposeur-libs || true
R=/usr/local/lib/transposeur/webrelay.py
if [ -f "$R" ] && curl -fsSL "$RAW/webrelay.py" -o "$T" && grep -q "Relais web du transposeur" "$T" && ! cmp -s "$T" "$R"; then
  install -m 644 "$T" "$R" && systemctl restart transposeur-web && echo "Relais web mis à jour"
fi
[ -f "$R" ] || echo "Relais web absent : relancez install.sh sur l'hôte Proxmox pour l'installer."
UPD
  push "$ct" "$t" /usr/local/bin/update 755
  rm -f "$t"

  info "Bibliothèques PDF et OCR (copie locale)…"
  pct exec "$ct" -- /usr/local/bin/transposeur-libs >/dev/null 2>&1 \
    || warn "Bibliothèques non copiées dans le conteneur : la page les chargera depuis Internet (CDN)."
  pct exec "$ct" -- systemctl enable caddy >/dev/null 2>&1 || true
  pct exec "$ct" -- systemctl restart caddy
  HTTPS="$https"
}

deploy_page(){ # deploy_page ctid   (la page est déjà dans $PAGE)
  local t
  pct exec "$1" -- mkdir -p "$WEBROOT"
  push "$1" "$PAGE" "$WEBROOT/index.html" 644
  t="$(mktemp)"; echo "$VERSION" > "$t"
  push "$1" "$t" "$WEBROOT/VERSION" 644
  rm -f "$t"
}

check(){ # check ctid   (grep sans -q : il lit toute la réponse, sinon curl échoue quand grep s'arrête au premier résultat)
  local ip; ip="$(ct_ip "$1" || true)"
  [[ -n "$ip" ]] || { warn "Adresse IP du conteneur introuvable pour l'instant."; return 0; }
  if curl -fsS -m 8 "http://$ip/" 2>/dev/null | grep "Transposeur de recettes" >/dev/null; then ok "Page servie : ${B}http://$ip${N}"
  else warn "La page ne répond pas encore sur http://$ip (journal : pct exec $1 -- journalctl -u caddy -n 30)"; fi
  if [[ "$(ct_conf "$1" HTTPS)" == 1 ]]; then
    if curl -fsSk -m 8 "https://$ip/" 2>/dev/null | grep "Transposeur de recettes" >/dev/null; then ok "Accès chiffré : ${B}https://$ip${N} (certificat interne : le navigateur demande de l'accepter une fois)"
    else warn "L'accès https://$ip ne répond pas encore."; fi
  fi
  if curl -fsS -m 8 "http://$ip/api/app/about" 2>/dev/null | grep '"version"' >/dev/null; then ok "Relais vers Mealie fonctionnel (/api)"
  else warn "Mealie ne répond pas à travers le relais. Vérifiez l'adresse : bash $NAME update --mealie HÔTE:PORT"; fi
  if curl -fsS -m 8 "http://$ip/web?ping=1" 2>/dev/null | grep '"ok"' >/dev/null; then ok "Relais web fonctionnel (/web) : recherche des recettes sur le site de l'auteur ou de l'éditeur"
  else warn "Relais web arrêté ou absent (journal : pct exec $1 -- journalctl -u transposeur-web -n 30)"; fi
  if curl -fsS -m 8 "http://$ip/lib/ok.json" 2>/dev/null | grep '"pdfjs"' >/dev/null; then ok "Bibliothèques PDF et OCR servies par le conteneur"
  else warn "Bibliothèques PDF et OCR absentes du conteneur : la page les charge depuis Internet."; fi
}

do_install(){
  get_page
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
  pveam list "$tstor" | grep "$tmpl" >/dev/null || { info "Téléchargement de $tmpl…"; pveam download "$tstor" "$tmpl" >/dev/null; }
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

  info "Installation de Caddy et de Python…"
  pct exec "$CTID" -- bash -c "export DEBIAN_FRONTEND=noninteractive; apt-get update -qq && apt-get install -y -qq caddy curl ca-certificates python3 >/dev/null"
  ok "Caddy installé"

  deploy_page "$CTID"; ok "Page déployée (version $VERSION)"
  setup_ct "$CTID" "$MEALIE" "${HTTPS:-0}"; ok "Relais /api → $MEALIE et relais web configurés"
  sleep 2; check "$CTID"
  echo -e "\n ${G}Terminé.${N} Ouvrez l'adresse ci-dessus, entrez votre jeton API Mealie, et c'est prêt."
  echo -e " Mise à jour plus tard : relancez la même commande sur l'hôte, ou tapez ${B}update${N} dans le conteneur.\n"
}

do_update(){
  local old cur
  [[ -n "$CTID" ]] || CTID="$(find_ct)" || die "Aucun conteneur étiqueté « $TAG ». Précisez --ctid N, ou lancez « install »."
  pct status "$CTID" >/dev/null 2>&1 || die "Conteneur $CTID introuvable."
  get_page
  echo -e "\n ${B}$APP — mise à jour du conteneur $CTID${N}\n"
  pct status "$CTID" | grep running >/dev/null || { info "Démarrage du conteneur…"; pct start "$CTID"; sleep 4; }
  old="$(pct exec "$CTID" -- cat "$WEBROOT/VERSION" 2>/dev/null || echo "inconnue")"
  deploy_page "$CTID"
  if [[ "$old" == "$VERSION" ]]; then ok "Page réinstallée (version $VERSION, inchangée)"; else ok "Page mise à jour : $old → $VERSION"; fi
  # la configuration est toujours réécrite : un conteneur installé par une ancienne version reçoit ainsi le relais web et les bibliothèques
  cur="$(ct_conf "$CTID" MEALIE)"
  if [[ -n "$MEALIE" ]]; then MEALIE="${MEALIE#http://}"; MEALIE="${MEALIE%/}"; else MEALIE="$cur"; fi
  [[ -n "$MEALIE" ]] || die "Adresse de Mealie inconnue : relancez avec --mealie HÔTE:PORT"
  [[ -n "$HTTPS" ]] || HTTPS="$(ct_conf "$CTID" HTTPS)"
  setup_ct "$CTID" "$MEALIE" "${HTTPS:-0}"
  if [[ "$MEALIE" != "$cur" ]]; then ok "Relais /api → $MEALIE reconfiguré"; else ok "Configuration du conteneur à jour"; fi
  if [[ $DO_OS -eq 1 ]]; then
    info "Mise à jour des paquets du conteneur…"
    pct exec "$CTID" -- bash -c "export DEBIAN_FRONTEND=noninteractive; apt-get update -qq && apt-get -y -qq dist-upgrade >/dev/null && apt-get -y -qq autoremove >/dev/null"
    ok "Paquets à jour"
  fi
  sleep 1; check "$CTID"; echo
}

do_status(){
  local latest
  [[ -n "$CTID" ]] || CTID="$(find_ct)" || die "Aucun conteneur étiqueté « $TAG »."
  latest="$(curl -fsSL -m 8 "$RAW/VERSION" 2>/dev/null | head -1 | tr -d '[:space:]' || true)"
  echo -e "\n ${B}$APP${N}"
  echo " Conteneur         : $CTID ($(pct status "$CTID" | awk '{print $2}'))"
  echo " Version installée : $(pct exec "$CTID" -- cat "$WEBROOT/VERSION" 2>/dev/null || echo "?")"
  echo " Dernière version  : ${latest:-?}"
  echo " Cible Mealie      : $(ct_conf "$CTID" MEALIE)"
  check "$CTID"; echo
}

if [[ -z "$ACTION" ]]; then
  if [[ -n "$CTID" ]] && pct status "$CTID" >/dev/null 2>&1; then ACTION=update
  elif find_ct >/dev/null; then ACTION=update
  else ACTION=install; fi
fi
case "$ACTION" in install) do_install;; update) do_update;; status) do_status;; esac
exit 0
