# GGUF Chat

Interface graphique PowerShell (WinForms) pour **télécharger, charger et discuter avec un modèle GGUF en local**, sans rien installer à la main. Le moteur d'inférence est [llama.cpp](https://github.com/ggml-org/llama.cpp) (`llama-server`), piloté en arrière-plan par le script.

Tout tient dans un seul fichier : `GGUFChat.ps1`.

---

## Fonctionnalités

- Téléchargement automatique de la **dernière release de llama.cpp** (CPU, Vulkan ou CUDA 12) depuis GitHub
- Téléchargement d'un modèle `.gguf` depuis Hugging Face ou n'importe quel lien direct, avec barre de progression, vitesse et bouton d'annulation
- Support des **modèles Hugging Face à accès restreint** via un token optionnel
- Démarrage / arrêt du serveur `llama-server` en arrière-plan (fenêtre masquée, journaux conservés)
- **Chat en streaming** : la réponse s'affiche au fil de l'eau
- Affichage du raisonnement (`reasoning_content`) des modèles « thinking » en gris italique
- Prompt système, température et nombre maximal de tokens réglables
- **Profils de contexte** (8k à 128k) qui règlent automatiquement cache KV, Flash Attention et placement du cache
- **Estimation mémoire (RAM / VRAM)** calculée en lisant les métadonnées du fichier GGUF
- **Auto-réglage GPU** : calcule le nombre de couches à décharger selon la VRAM disponible
- Compteur de contexte et vitesse de génération (tokens/s) en temps réel
- Gestion automatique du contexte plein (les plus anciens messages sont oubliés)

---

## Prérequis

| Élément | Détail |
|---|---|
| Système | Windows 10 / 11 (x64) |
| PowerShell | Windows PowerShell 5.1 (inclus dans Windows) |
| Réseau | Accès à `api.github.com`, `github.com` et au site hébergeant le modèle (ex. `huggingface.co`) |
| GPU (optionnel) | Carte compatible Vulkan, ou NVIDIA avec pilote CUDA 12 |
| Espace disque | Selon le modèle (de quelques centaines de Mo à plusieurs dizaines de Go) |

Aucune installation de Python, Node ou autre dépendance n'est nécessaire.

---

## Lancement

```powershell
powershell -STA -ExecutionPolicy Bypass -File "C:\Users\t.langlois-teston\Documents\_TAFF\_Script\LLM\GGUFChat.ps1"
```

Ou via un double-clic sur `Lancer.bat`.

> WinForms exige le mode STA. Si le script est lancé sans `-STA`, il se **relance automatiquement** dans une nouvelle instance PowerShell en mode STA (fenêtre console masquée), puis ferme l'instance d'origine.

---

## Prise en main rapide

1. **Moteur** : choisissez le backend (`CPU`, `Vulkan` ou `CUDA 12`) puis cliquez sur **Télécharger llama.cpp** (à faire une seule fois). Le champ *Moteur* se remplit tout seul. Vous pouvez aussi pointer vers votre propre `llama-server.exe` avec le bouton `...`.
2. **Modèle** : collez l'URL d'un fichier `.gguf` dans *URL GGUF* puis cliquez sur **Télécharger le modèle**. Vous pouvez aussi choisir un fichier local avec le bouton `...`.
3. **Réglages** : sélectionnez un *Profil* de contexte, renseignez votre VRAM puis cliquez sur **Auto-régler GPU**.
4. **Démarrer le serveur** : attendez que l'indicateur passe au vert (« Serveur : prêt »).
5. **Discuter** : tapez votre message, `Entrée` pour envoyer, `Maj+Entrée` pour un retour à la ligne.

---

## Description de l'interface

### Zone supérieure : configuration

| Champ / bouton | Rôle |
|---|---|
| **Moteur** | Chemin vers `llama-server.exe` (détecté automatiquement s'il a déjà été téléchargé) |
| **Backend** + **Télécharger llama.cpp** | Télécharge et extrait la dernière release (CPU, Vulkan ou CUDA 12) |
| **Modèle** | Liste des `.gguf` du dossier des modèles, triés du plus récent au plus ancien |
| **Actualiser** / **Ouvrir le dossier des modèles** | Rafraîchit la liste / ouvre le dossier dans l'Explorateur |
| **URL GGUF** | Lien direct vers un `.gguf`. Les liens Hugging Face `/blob/` sont convertis en `/resolve/` automatiquement |
| **Token HF** | Token Hugging Face optionnel (modèles Llama, Gemma, etc.). Il n'est envoyé qu'aux hôtes `*.huggingface.co` |
| **Annuler** | Interrompt le téléchargement en cours (le fichier partiel est supprimé) |
| **Profil** | Préréglages de contexte (voir tableau ci-dessous) |
| **Contexte** | Taille du contexte en tokens (`-c`) |
| **Couches GPU** | Nombre de couches déchargées sur le GPU (`-ngl`). `0` = tout sur CPU, `99` = tout sur GPU |
| **VRAM Go** | VRAM dédiée réellement utilisable (laisser ~0,5 Go à Windows) |
| **Temp.** | Température d'échantillonnage (0 à 2) |
| **Max tokens** | Longueur maximale d'une réponse (`-1` = illimité) |
| **Cache KV** | Précision du cache : `f16`, `q8_0` ou `q4_0` |
| **Flash Attention** | Réduit fortement la mémoire de calcul. Obligatoire pour quantifier le cache KV |
| **Cache KV en RAM (-nkvo)** | Garde le cache KV en RAM pour libérer de la VRAM |
| **Threads** | Cœurs utilisés pour le calcul CPU |
| **Démarrer / Arrêter / Journal** | Contrôle du serveur et ouverture du journal d'erreurs dans le Bloc-notes |
| **Auto-régler GPU** | Calcule le nombre de couches GPU qui tiennent dans la VRAM indiquée |
| **Système** | Prompt système envoyé avec chaque requête |

### Zone centrale : conversation

Affiche l'historique (`Vous` en bleu, `IA` en vert). Le raisonnement des modèles « thinking » apparaît en gris italique, les erreurs en rouge.

### Zone inférieure : saisie

| Bouton | Rôle |
|---|---|
| **Envoyer** | Envoie le message (actif uniquement quand le serveur est prêt) |
| **Stop génération** | Interrompt la réponse en cours |
| **Effacer** | Vide la conversation et l'historique |

---

## Profils de contexte

| Profil | Contexte | Cache KV | Flash Attention | Cache KV en RAM |
|---|---|---|---|---|
| Équilibré (8k) | 8 192 | f16 | oui | non |
| Long (16k) | 16 384 | q8_0 | oui | non |
| Très long (32k) | 32 768 | q8_0 | oui | oui |
| Ultra (64k) | 65 536 | q8_0 | oui | oui |
| Extrême (128k) | 131 072 | q4_0 | oui | oui |

Le profil par défaut est **Long (16k)**. Modifier manuellement la valeur de *Contexte* repasse le profil sur *Personnalisé*. Choisir un profil relance automatiquement l'auto-réglage GPU si un modèle est sélectionné.

**Choix du cache KV** : `f16` = qualité maximale, `q8_0` = 2x moins de mémoire pour une perte minime, `q4_0` = environ 3,5x moins de mémoire avec une perte visible.

---

## Estimation mémoire et auto-réglage GPU

Le script lit directement l'en-tête du fichier GGUF (architecture, nombre de couches, dimensions d'embedding, têtes d'attention, contexte d'entraînement) pour estimer :

- la taille du **cache KV** : `contexte x couches x têtes_kv x (longueur_clé + longueur_valeur) x octets_par_élément`
- la **RAM** nécessaire (modèle + cache KV non déchargés + marge)
- la **VRAM** nécessaire (couches déchargées + cache KV éventuel + marge)

Le texte d'estimation change de couleur :

| Couleur | Signification |
|---|---|
| Vert | Tient confortablement |
| Orange | Proche de la limite (RAM > 80 % du libre ou VRAM > valeur indiquée) |
| Rouge | Risque de dépassement (RAM > 95 % du libre ou VRAM > 105 %) |

Un avertissement s'affiche si le contexte demandé dépasse le **contexte d'entraînement** du modèle. Les modèles découpés en plusieurs fichiers (`...-00001-of-00003.gguf`) sont pris en compte dans leur ensemble.

> Il s'agit d'une **estimation** : la consommation réelle dépend de la version de llama.cpp et du backend.

---

## Gestion du contexte

Le script suit l'occupation du contexte grâce aux statistiques renvoyées par le serveur. Quand elle dépasse **80 %** du contexte actif, les plus anciens échanges (par paires utilisateur/assistant) sont supprimés de l'historique avant l'envoi du message suivant, et un message orange le signale dans le chat.

---

## Fichiers et dossiers

Tout est stocké dans `%LOCALAPPDATA%\GGUFChat` :

| Dossier | Contenu |
|---|---|
| `bin\` | Binaires llama.cpp extraits |
| `models\` | Modèles `.gguf` téléchargés |
| `logs\` | `server.out.log` et `server.err.log` (sortie du serveur) |

Pour désinstaller complètement, supprimez ce dossier.

---

## Fonctionnement technique

- **Serveur** : `llama-server.exe` est lancé en fenêtre masquée avec : `-m <modèle> --host 127.0.0.1 --port 8089 -c <contexte> -ngl <couches> -np 1 -t <threads> --jinja`, plus selon les options `--flash-attn on`, `-ctk/-ctv <type>` et `--no-kv-offload`.
- **Sécurité réseau** : le serveur écoute uniquement sur `127.0.0.1:8089`, il n'est donc pas accessible depuis le réseau.
- **Détection de disponibilité** : l'interface interroge `/health` toutes les secondes jusqu'à la réponse du serveur.
- **API** : les conversations passent par l'endpoint compatible OpenAI `POST /v1/chat/completions` en mode `stream`, lu ligne à ligne (SSE).
- **Interface fluide** : téléchargements et requêtes de chat s'exécutent dans des **runspaces** séparés. L'interface communique avec eux par une table de hachage synchronisée et une file concurrente, et ne se fige donc jamais.
- **Téléchargements** : `HttpWebRequest` avec gestion manuelle des redirections (10 max). Le fichier est écrit en `.part` puis renommé une fois terminé.
- **Choix des binaires llama.cpp** : sélection par expression régulière dans les assets de la dernière release. Pour CUDA 12, le runtime `cudart` est téléchargé en plus.
- **Fermeture** : à la fermeture de la fenêtre, les téléchargements sont annulés et le serveur est arrêté.

---

## Dépannage

| Problème | Piste |
|---|---|
| Le serveur s'arrête juste après le démarrage | Le message d'erreur affiche les 10 dernières lignes du journal. Cliquez sur **Journal** pour le détail. Cause fréquente : mémoire insuffisante, réduisez le contexte ou augmentez les couches sur CPU |
| Erreur 401 / 403 au téléchargement | Modèle à accès restreint : acceptez la licence sur Hugging Face et renseignez un **Token HF** |
| « L'URL doit pointer vers un fichier .gguf » | Utilisez un lien direct vers le fichier (`.../resolve/main/xxx.gguf`) |
| Aucun binaire Windows trouvé dans la release | Les noms des assets de llama.cpp ont peut-être changé : téléchargez-le manuellement et indiquez `llama-server.exe` via `...` |
| Génération très lente | Vérifiez le nombre de **Couches GPU** (0 = CPU uniquement) et le backend téléchargé (Vulkan / CUDA). Évitez un nombre de threads supérieur aux cœurs physiques |
| Le modèle plante en utilisant la VRAM | Ne comptez que la VRAM dédiée (la mémoire partagée est trop lente). Baissez les couches GPU ou activez `-nkvo` |
| Estimation « indisponible » | Architecture du modèle non reconnue : réglez les couches GPU à la main |
| Port 8089 déjà utilisé | Modifiez la variable `$Port` en haut du script |

---

## Personnalisation

Les principaux paramètres se trouvent au début du script, section **Configuration** :

```powershell
$AppDir   = Join-Path $env:LOCALAPPDATA 'GGUFChat'   # dossier de travail
$Port     = 8089                                      # port du serveur local
```

Autres valeurs modifiables : URL et prompt système par défaut (champs `$tbUrl` et `$tbSystem`), profils de contexte (événement `$cbProfile.Add_SelectedIndexChanged`) et marges mémoire dans `Get-Estimate`.

---

## Limites connues

- Windows uniquement (WinForms, binaires `win-x64`)
- Une seule conversation et un seul modèle chargé à la fois (`-np 1`)
- L'historique n'est pas sauvegardé : il est perdu à la fermeture ou avec **Effacer**
- Texte uniquement (pas d'images ni de pièces jointes)
- Le token Hugging Face n'est pas mémorisé entre deux sessions

---

## Crédits

- [llama.cpp](https://github.com/ggml-org/llama.cpp) (licence MIT) pour le moteur d'inférence
- [Hugging Face](https://huggingface.co) pour l'hébergement de nombreux modèles GGUF
