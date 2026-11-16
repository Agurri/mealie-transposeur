# Journal des changements

## 2026.11.16-2

- **Onglets** : « Livre », « Recette » et « Réglages ». Sur grand écran, Livre et Recette restent côte à côte.
- La connexion à Mealie, les options d'envoi et l'import manuel JSON sont dans « Réglages ». Une ligne sous le titre indique l'état de la connexion ; sans jeton, la page s'ouvre sur les Réglages.
- La connexion est vérifiée au chargement, et les options d'envoi sont mémorisées sur l'appareil.
- Options avancées repliées sous « Plus d'options » : méthode de lecture, langue de l'OCR, pages à analyser, pages de la table des matières.
- **Comparaison livre / site côte à côte** pour les recettes trouvées en ligne, avec les ingrédients sans équivalent mis en évidence.

## 2026.11.16-1

Nouveautés
- **Recettes aussi publiées en ligne** : indiquez le site de l'auteur ou de l'éditeur ; les recettes du livre y sont recherchées (plan du site), et pour chacune de celles retrouvées vous choisissez la version à importer, livre ou site, avant l'envoi. L'adresse d'une recette peut aussi être indiquée à la main.
- **Version affichée** en haut de la page.
- Accès chiffré facultatif : `bash install.sh update --https` (certificat interne de Caddy).

Corrections et améliorations
- pdf.js passe de 3.11.174 à 4.10.38 (faille CVE-2024-4367 corrigée), avec `isEvalSupported` désactivé.
- Les bibliothèques PDF et OCR sont copiées dans le conteneur et vérifiées par empreinte SHA-256 : la page fonctionne sans Internet et ne dépend plus du CDN (qui reste la solution de repli).
- Livre numérisé : jusqu'à trois pages océrisées en même temps.
- La liste du lot est sauvegardée dans IndexedDB : plus de limite de taille gênante, et les photos choisies à la main survivent au rechargement.
- Mise à jour d'une recette : la copie temporaire laissée dans Mealie par un envoi interrompu est supprimée à l'envoi suivant.
- Les sous-titres d'ingrédients et d'étapes ne sont posés que si Mealie a gardé le même découpage.
- La version est inscrite dans la page elle-même : page et numéro de version ne peuvent plus diverger. Un téléchargement tronqué est refusé.
- La mise à jour (hôte ou conteneur) rafraîchit aussi les bibliothèques et le relais web ; sur l'hôte, elle réécrit toujours la configuration de Caddy.
- `install.sh` : le contrôle final n'annonce plus à tort « la page ne répond pas ».
- La lecture en arrière-plan (photos, analyse) n'écrase plus le message de la section 1.
- Avertissement quand le jeton est mémorisé sur une page servie en HTTP.
- Tests automatiques (analyse, recherche web, relais) lancés à chaque envoi sur GitHub.

## 2026.11.15-4

Première version publiée.
