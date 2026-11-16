# Transposeur de recettes → Mealie

Une page web unique qui transforme un livre de recettes (PDF, EPUB, numérisation ou photo) en recettes importées dans [Mealie](https://mealie.io) : titre, ingrédients, étapes, sections, photo, pages d'origine en pièces jointes et étiquette au nom du livre.

Tout le traitement se fait dans le navigateur. La page ne parle qu'à votre serveur Mealie et, si vous le demandez, au site de l'auteur ou de l'éditeur du livre.

## Installation sur Proxmox

Sur l'hôte Proxmox, en root :

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/Agurri/mealie-transposeur/main/install.sh)"
```

Le script crée un petit conteneur LXC (Debian + Caddy) qui :

- sert la page, avec une copie locale des bibliothèques PDF et OCR (vérifiées par empreinte SHA-256) ;
- relaie `/api/` vers Mealie : la page et l'API ont la même adresse, ce qui évite le blocage CORS du navigateur ;
- relaie `/web` vers les sites publics de recettes (voir « Recettes aussi publiées en ligne »).

## Mise à jour

Relancez la même commande sur l'hôte : la page, les bibliothèques, le relais web et la configuration de Caddy sont mis à jour. Dans le conteneur, la commande `update` fait de même, sauf pour la configuration de Caddy.

La version installée est affichée en haut de la page. Les changements sont décrits dans [CHANGELOG.md](CHANGELOG.md).

Autres commandes (après `curl -fsSLO …/install.sh`) :

| Commande | Effet |
|---|---|
| `bash install.sh status` | conteneur, version installée, état des relais et des bibliothèques |
| `bash install.sh update --mealie IP:9000` | change l'adresse de Mealie |
| `bash install.sh update --https` | ajoute l'accès chiffré `https://ADRESSE_DU_CONTENEUR` |
| `bash install.sh update --no-https` | le retire |
| `bash install.sh update --os` | met aussi à jour les paquets du conteneur |

Avec `--https`, Caddy utilise son certificat interne : le navigateur demande de l'accepter une fois. Le certificat est émis pour l'adresse IP du conteneur au moment de la commande ; donnez-lui une adresse fixe, ou relancez la commande si elle change. L'accès HTTP reste disponible.

## Utilisation

1. Ouvrez `http://ADRESSE_DU_CONTENEUR` et collez votre jeton API Mealie (Profil → Jetons API).
2. Chargez un PDF ou un EPUB.
3. « Analyser le livre » : les recettes sont repérées à l'aide de la table des matières ou de l'index.
4. Vérifiez la liste, corrigez au besoin, puis « Envoyer dans Mealie ».

Une recette déjà présente dans Mealie est mise à jour plutôt que dupliquée ; deux recettes différentes du même nom reçoivent leur source dans le titre.

### Recettes aussi publiées en ligne

Certaines recettes d'un livre sont aussi sur le site de son auteur ou de son éditeur, souvent mieux structurées et avec leur photo.

1. Dans « Lot — livre entier », indiquez l'adresse du site (par exemple `www.exemple.com`).
2. Après l'analyse du livre, ou avec « Chercher sur le site », chaque titre est recherché dans le plan du site (sitemap), puis la page trouvée est lue pour vérifier qu'elle contient bien cette recette.
3. Les recettes retrouvées portent un menu « Livre ou site ? » dans la liste. Le choix est obligatoire, recette par recette ou pour toutes d'un coup : rien n'est envoyé tant qu'il manque.

Avec « Site web », la recette du site est importée telle quelle, avec sa photo et son adresse d'origine ; l'étiquette du livre, la source (livre et page) et les pages d'origine en pièces jointes sont conservées. Si le site n'a pas de plan lisible, touchez une recette puis « Indiquer l'adresse de cette recette sur le web ».

Limites : le site doit publier un plan (sitemap) et décrire ses recettes au format schema.org, ce que font la plupart des sites de recettes. Le relais ne lit que des sites publics : les adresses du réseau local sont refusées.

## Fichiers

- `index.html` : la page (utilisable seule, mais l'envoi vers Mealie et la recherche sur le web exigent le conteneur).
- `install.sh` : installation et mise à jour du conteneur.
- `webrelay.py` : relais web lancé dans le conteneur.
- `libs.txt` : bibliothèques copiées dans le conteneur, avec leur empreinte.
- `VERSION` : version publiée (la même que celle inscrite dans la page).
- `tests/` : tests automatiques — `node tests/run.mjs` et `python3 tests/test_webrelay.py`.

Ouverte hors du conteneur, la page charge pdf.js et Tesseract.js depuis un CDN : une connexion Internet est alors nécessaire pour lire les PDF et faire l'OCR.
