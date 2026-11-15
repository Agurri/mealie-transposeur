# Transposeur de recettes → Mealie

Une page web unique qui transforme un livre de recettes (PDF, EPUB, numérisation ou photo) en recettes importées dans [Mealie](https://mealie.io) : titre, ingrédients, étapes, sections, photo, pages d'origine en pièces jointes et étiquette au nom du livre.

Tout le traitement se fait dans le navigateur. La page n'envoie rien ailleurs que vers votre propre serveur Mealie.

## Installation sur Proxmox

Sur l'hôte Proxmox, en root :

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/Agurri/mealie-transposeur/main/install.sh)"
```

Le script crée un petit conteneur LXC (Debian + Caddy) qui sert la page et relaie `/api/` vers Mealie. La page et l'API ont alors la même adresse, ce qui évite le blocage CORS du navigateur.

## Mise à jour

Relancez la même commande sur l'hôte, ou tapez `update` dans le conteneur. Les deux récupèrent la dernière version de `index.html` depuis ce dépôt.

Autres commandes (après `curl -fsSLO …/install.sh`) :

| Commande | Effet |
|---|---|
| `bash install.sh status` | conteneur, version installée, état du relais |
| `bash install.sh update --mealie IP:9000` | change l'adresse de Mealie |
| `bash install.sh update --os` | met aussi à jour les paquets du conteneur |

## Utilisation

1. Ouvrez `http://ADRESSE_DU_CONTENEUR` et collez votre jeton API Mealie (Profil → Jetons API).
2. Chargez un PDF ou un EPUB.
3. « Analyser le livre » : les recettes sont repérées à l'aide de la table des matières ou de l'index.
4. Vérifiez la liste, corrigez au besoin, puis « Envoyer dans Mealie ».

Une recette déjà présente dans Mealie est mise à jour plutôt que dupliquée ; deux recettes différentes du même nom reçoivent leur source dans le titre.

## Fichiers

- `index.html` : la page (utilisable seule, mais l'envoi direct vers Mealie exige le relais ci-dessus).
- `install.sh` : installation et mise à jour du conteneur.
- `VERSION` : version publiée.

Sans connexion Internet, la lecture des PDF et l'OCR ne fonctionnent pas : les bibliothèques pdf.js et Tesseract.js sont chargées depuis un CDN.
