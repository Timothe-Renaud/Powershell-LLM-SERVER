-- internationale version
# GGUF Chat

A PowerShell (WinForms) graphical interface to **download, load and chat with a GGUF model locally**, with no manual setup. The inference engine is [llama.cpp](https://github.com/ggml-org/llama.cpp) (`llama-server`), driven in the background by the script.

Everything lives in a single file: `GGUFChat.ps1`.

> **Note:** the application's interface (buttons, labels, messages) is in French. This README gives the English meaning of each element, with the French label in parentheses so you can find it on screen.

---

## Features

- Automatic download of the **latest llama.cpp release** (CPU, Vulkan or CUDA 12) from GitHub
- Download of a `.gguf` model from Hugging Face or any direct link, with progress bar, speed display and a cancel button
- Support for **gated Hugging Face models** through an optional access token
- Start / stop the `llama-server` process in the background (hidden window, logs kept)
- **Streaming chat**: the reply is displayed live as it is generated
- Display of the reasoning stream (`reasoning_content`) of "thinking" models in grey italics
- Adjustable system prompt, temperature and maximum tokens
- **Context profiles** (8k to 128k) that automatically set KV cache type, Flash Attention and cache placement
- **Memory estimation (RAM / VRAM)** computed by reading the GGUF file metadata
- **GPU auto-tuning**: computes how many layers to offload based on your available VRAM
- Live context usage and generation speed (tokens/s)
- Automatic handling of a full context (oldest messages are dropped)

---

## Requirements

| Item | Details |
|---|---|
| OS | Windows 10 / 11 (x64) |
| PowerShell | Windows PowerShell 5.1 (built into Windows) |
| Network | Access to `api.github.com`, `github.com` and the site hosting your model (e.g. `huggingface.co`) |
| GPU (optional) | Vulkan-capable card, or NVIDIA with a CUDA 12 driver |
| Disk space | Depends on the model (from a few hundred MB to several tens of GB) |

No Python, Node or any other dependency is required.

---

## Launching

```powershell
cd c:\XX\XX\XX\Folder\
powershell -STA -ExecutionPolicy Bypass -File .\GGUFChat.ps1
```

Or double-click a `Lancer.bat` launcher if you have one.

> WinForms requires STA mode. If the script is started without `-STA`, it **automatically relaunches itself** in a new STA PowerShell instance (hidden console window) and the original instance exits.

---

## Quick start

1. **Engine**: pick the backend (`CPU`, `Vulkan` or `CUDA 12`) and click **Download llama.cpp** (*Télécharger llama.cpp*). Only needed once. The *Engine* field fills in automatically. You can also point to your own `llama-server.exe` with the `...` button.
2. **Model**: paste the URL of a `.gguf` file into *GGUF URL* and click **Download the model** (*Télécharger le modèle*). You can also pick a local file with the `...` button.
3. **Settings**: choose a context *Profile*, enter your VRAM, then click **Auto-tune GPU** (*Auto-régler GPU*).
4. **Start the server** (*Démarrer le serveur*) and wait for the status line to turn green ("Serveur : prêt").
5. **Chat**: type your message, `Enter` to send, `Shift+Enter` for a new line.

---

## Interface reference

### Top area: configuration

| Field / button | Purpose |
|---|---|
| **Engine** (*Moteur*) | Path to `llama-server.exe` (auto-detected if already downloaded) |
| **Backend** + **Download llama.cpp** | Downloads and extracts the latest release (CPU, Vulkan or CUDA 12) |
| **Model** (*Modèle*) | List of `.gguf` files in the models folder, newest first |
| **Refresh** (*Actualiser*) / **Open models folder** (*Ouvrir le dossier des modèles*) | Refreshes the list / opens the folder in Explorer |
| **GGUF URL** (*URL GGUF*) | Direct link to a `.gguf` file. Hugging Face `/blob/` links are automatically converted to `/resolve/` |
| **HF Token** (*Token HF*) | Optional Hugging Face token (Llama, Gemma, etc.). Only sent to `*.huggingface.co` hosts |
| **Cancel** (*Annuler*) | Aborts the current download (the partial file is deleted) |
| **Profile** (*Profil*) | Context presets (see table below) |
| **Context** (*Contexte*) | Context size in tokens (`-c`) |
| **GPU layers** (*Couches GPU*) | Number of layers offloaded to the GPU (`-ngl`). `0` = all on CPU, `99` = everything on GPU |
| **VRAM GB** (*VRAM Go*) | Dedicated VRAM you can actually use (leave ~0.5 GB for Windows) |
| **Temp.** | Sampling temperature (0 to 2) |
| **Max tokens** | Maximum length of a reply (`-1` = unlimited) |
| **KV cache** (*Cache KV*) | Cache precision: `f16`, `q8_0` or `q4_0` |
| **Flash Attention** | Greatly reduces compute memory. Required to quantize the KV cache |
| **KV cache in RAM (-nkvo)** (*Cache KV en RAM*) | Keeps the KV cache in RAM to free up VRAM |
| **Threads** | CPU cores used for computation |
| **Start / Stop / Log** (*Démarrer / Arrêter / Journal*) | Server control, and opens the error log in Notepad |
| **Auto-tune GPU** | Computes how many GPU layers fit in the VRAM you entered |
| **System** (*Système*) | System prompt sent with every request |

### Middle area: conversation

Shows the chat history (`Vous` / You in blue, `IA` / AI in green). The reasoning of "thinking" models appears in grey italics, errors in red.

### Bottom area: input

| Button | Purpose |
|---|---|
| **Send** (*Envoyer*) | Sends the message (only enabled once the server is ready) |
| **Stop generation** (*Stop génération*) | Interrupts the reply in progress |
| **Clear** (*Effacer*) | Clears the conversation and the history |

---

## Context profiles

| Profile | Context | KV cache | Flash Attention | KV cache in RAM |
|---|---|---|---|---|
| Balanced (8k) | 8,192 | f16 | yes | no |
| Long (16k) | 16,384 | q8_0 | yes | no |
| Very long (32k) | 32,768 | q8_0 | yes | yes |
| Ultra (64k) | 65,536 | q8_0 | yes | yes |
| Extreme (128k) | 131,072 | q4_0 | yes | yes |

The default profile is **Long (16k)**. Manually changing the *Context* value switches the profile to *Custom* (*Personnalisé*). Selecting a profile automatically re-runs GPU auto-tuning when a model is selected.

**KV cache choice:** `f16` = maximum quality, `q8_0` = 2x less memory with minimal loss, `q4_0` = about 3.5x less memory with a noticeable loss.

---

## Memory estimation and GPU auto-tuning

The script reads the GGUF file header directly (architecture, layer count, embedding size, attention heads, training context) to estimate:

- the **KV cache** size: `context x layers x kv_heads x (key_length + value_length) x bytes_per_element`
- the **RAM** required (model + non-offloaded KV cache + overhead)
- the **VRAM** required (offloaded layers + KV cache if offloaded + overhead)

The estimate text changes color:

| Color | Meaning |
|---|---|
| Green | Fits comfortably |
| Orange | Close to the limit (RAM > 80% of free, or VRAM above the value entered) |
| Red | Likely to overflow (RAM > 95% of free, or VRAM > 105%) |

A warning is shown if the requested context exceeds the model's **training context**. Models split across several files (`...-00001-of-00003.gguf`) are handled as a whole.

> This is an **estimate**: actual usage depends on the llama.cpp version and backend.

---

## Context management

The script tracks context usage from the statistics returned by the server. When usage exceeds **80%** of the active context, the oldest exchanges (removed in user/assistant pairs) are dropped from the history before the next message is sent, and an orange notice is shown in the chat.

---

## Files and folders

Everything is stored in `%LOCALAPPDATA%\GGUFChat`:

| Folder | Contents |
|---|---|
| `bin\` | Extracted llama.cpp binaries |
| `models\` | Downloaded `.gguf` models |
| `logs\` | `server.out.log` and `server.err.log` (server output) |

To uninstall completely, delete this folder.

---

## How it works

- **Server:** `llama-server.exe` is started with a hidden window using: `-m <model> --host 127.0.0.1 --port 8089 -c <context> -ngl <layers> -np 1 -t <threads> --jinja`, plus `--flash-attn on`, `-ctk/-ctv <type>` and `--no-kv-offload` depending on the options.
- **Network exposure:** the server only listens on `127.0.0.1:8089`, so it is not reachable from the network.
- **Readiness check:** the UI polls `/health` every second until the server responds.
- **API:** conversations use the OpenAI-compatible `POST /v1/chat/completions` endpoint in `stream` mode, read line by line (SSE).
- **Responsive UI:** downloads and chat requests run in separate **runspaces**. The UI communicates with them through a synchronized hashtable and a concurrent queue, so it never freezes.
- **Downloads:** `HttpWebRequest` with manual redirect handling (10 max). The file is written as `.part` and renamed once complete.
- **llama.cpp binary selection:** matched by regular expression against the assets of the latest release. For CUDA 12, the `cudart` runtime is downloaded as well.
- **On close:** downloads are cancelled and the server is stopped.

---

## Troubleshooting

| Problem | Suggestion |
|---|---|
| Server stops right after starting | The error popup shows the last 10 log lines. Click **Log** for details. Common cause: not enough memory, so reduce the context or run more layers on CPU |
| 401 / 403 error when downloading | Gated model: accept the license on Hugging Face and enter an **HF Token** |
| "L'URL doit pointer vers un fichier .gguf" | Use a direct link to the file (`.../resolve/main/xxx.gguf`) |
| No Windows binary found in the release | llama.cpp asset names may have changed: download it manually and select `llama-server.exe` with `...` |
| Very slow generation | Check **GPU layers** (0 = CPU only) and the downloaded backend (Vulkan / CUDA). Avoid more threads than physical cores |
| Model crashes when using VRAM | Only count dedicated VRAM (shared memory is too slow). Lower the GPU layers or enable `-nkvo` |
| Estimate shows "unavailable" | Model architecture not recognized: set GPU layers manually |
| Port 8089 already in use | Change the `$Port` variable at the top of the script |

---

## Customization

The main settings are at the top of the script, in the **Configuration** section:

```powershell
$AppDir   = Join-Path $env:LOCALAPPDATA 'GGUFChat'   # working folder
$Port     = 8089                                      # local server port
```

Other editable values: default URL and system prompt (`$tbUrl` and `$tbSystem` fields), context profiles (`$cbProfile.Add_SelectedIndexChanged` event) and memory margins in `Get-Estimate`.

---

## Known limitations

- Windows only (WinForms, `win-x64` binaries)
- One conversation and one loaded model at a time (`-np 1`)
- History is not saved: it is lost on close or with **Clear**
- Text only (no images or attachments)
- The Hugging Face token is not remembered between sessions
- The interface language is French (translating the UI strings would require editing the script)

---

## Credits

- [llama.cpp](https://github.com/ggml-org/llama.cpp) (MIT license) for the inference engine
- [Hugging Face](https://huggingface.co) for hosting many GGUF models


--Version Francaise

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
cd c:\XX\XX\XX\Dossier\
powershell -STA -ExecutionPolicy Bypass -File .\GGUFChat.ps1
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
