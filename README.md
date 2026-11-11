# Vocal

Vocal transforme chaque mémo du Dictaphone d'Apple, enregistré sur l'Apple Watch, l'iPhone ou l'iPad, en note Markdown dans le dossier de votre choix, par exemple l'inbox d'un coffre Obsidian. La transcription se fait sur le Mac, avec la reconnaissance vocale d'Apple. Un LLM peut, en option, donner un titre, un résumé et un texte nettoyé.

```text
mémo enregistré sur la Watch
  → synchronisé par iCloud sur le Mac (une vingtaine de secondes)
  → launchd lance Vocal dès que le dossier du Dictaphone change
  → transcription locale (SpeechAnalyzer d'Apple)
  → titre, résumé et texte nettoyé par un LLM (facultatif)
  → note Markdown dans votre inbox, environ 40 secondes après la fin de l'enregistrement
```

Vocal est une petite app en ligne de commande, sans interface, écrite en Swift. Elle ne modifie, ne déplace ni ne supprime jamais un mémo du Dictaphone.

## À qui s'adresse Vocal

- Mac avec puce Apple, sous **macOS 26 ou plus récent** (développé et utilisé sous macOS 27).
- Mémos du Dictaphone synchronisés par **iCloud** sur ce Mac (Réglages Système, votre compte Apple, iCloud, Dictaphone).
- **Xcode 26** ou ses outils en ligne de commande, pour Swift 6.2.
- Une personne à l'aise avec le terminal : l'installation se fait en quelques commandes.
- Facultatif : **Obsidian**, et un LLM accessible par une API compatible OpenAI ou Anthropic, local ou dans le cloud.

Les mémos sont transcrits en français par défaut. Une autre langue se règle avec `locale`, mais la consigne donnée au LLM est écrite pour le français.

## Installation

### 1. Construire l'app

```bash
git clone https://github.com/Bricesodini/vocal.git
cd vocal
swift test
```

Choisissez un identifiant d'app stable, à vous, dans un fichier local ignoré par Git. macOS y attache l'Accès complet au disque et la réservation du modèle de transcription :

```bash
echo 'VOCAL_BUNDLE_ID=com.votrenom.vocal' > scripts/identite.local
scripts/build-app.sh
```

L'app est signée avec le certificat « Apple Development » de votre trousseau ; un compte Apple gratuit, ajouté dans Xcode, suffit pour l'obtenir. Sans certificat, ajoutez `VOCAL_SIGNATURE=-` dans `scripts/identite.local` : l'app est alors signée sans identité, et l'Accès complet au disque est à redonner après chaque construction.

Installez l'app à son emplacement définitif :

```bash
mkdir -p ~/Applications
cp -R build/Vocal.app ~/Applications/Vocal.app
```

Pour une mise à jour, mettez d'abord l'ancienne `~/Applications/Vocal.app` à la Corbeille.

### 2. Donner accès au dossier du Dictaphone

Le Dictaphone range ses mémos dans `~/Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings`, un dossier protégé par macOS. Dans Réglages Système, Confidentialité et sécurité, **Accès complet au disque**, ajoutez `~/Applications/Vocal.app`, et elle seule : jamais le Terminal ni un interpréteur.

### 3. Installer le modèle de transcription

```bash
~/Applications/Vocal.app/Contents/MacOS/Vocal modèle --installer
```

### 4. Régler Vocal

Créez `~/.config/vocal/vocal.json`. Le minimum, sans LLM :

```json
{
  "inbox": "~/Documents/MonCoffre/0 INBOX"
}
```

Le dossier `inbox` doit exister : Vocal ne le crée jamais, et n'écrit nulle part ailleurs dans votre coffre.

Avec un LLM, sur le modèle des réglages d'opencode :

```json
{
  "inbox": "~/Documents/MonCoffre/0 INBOX",
  "locale": "fr_FR",
  "model": "minimax/MiniMax-M3.1-Flash",
  "providers": {
    "minimax": {
      "protocol": "anthropic",
      "baseURL": "https://api.minimax.io/anthropic/v1",
      "apiKey": "keychain:vocal-minimax",
      "timeoutSeconds": 120
    },
    "local": {
      "protocol": "openai-compatible",
      "baseURL": "http://localhost:11434/v1"
    }
  },
  "glossary": ["Markdown", "Obsidian"]
}
```

- `model` vaut `<fournisseur>/<modèle>`. Changer de modèle, c'est changer cette ligne. Sans `model`, aucun LLM n'est appelé.
- `protocol` vaut `openai-compatible` (Ollama, LM Studio, OpenRouter, et la plupart des fournisseurs) ou `anthropic` (Anthropic, MiniMax). Pour `anthropic`, `baseURL` vaut par défaut `https://api.anthropic.com/v1`.
- `glossary` liste vos termes récurrents : le LLM corrige un mot mal reconnu qui leur ressemble.

**Aucune clé d'API dans ce fichier** : une clé écrite en clair le fait refuser. La clé vit dans le trousseau macOS, dans une entrée qui autorise Vocal à la lire sans demande à l'écran. Cette commande demande la clé deux fois, sans l'afficher :

```bash
security add-generic-password -U -s vocal-minimax -a vocal -T "$HOME/Applications/Vocal.app" -w
```

Essayez sur un fichier audio quelconque, sans toucher à l'inbox :

```bash
mkdir -p /tmp/vocal-essai
~/Applications/Vocal.app/Contents/MacOS/Vocal essai Tests/Fixtures/watch.m4a --destination /tmp/vocal-essai
```

### 5. Lancer Vocal automatiquement

```bash
scripts/launchd-vocal.sh
cp build/com.votrenom.vocal.plist ~/Library/LaunchAgents/
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.votrenom.vocal.plist
```

launchd lance un passage dès que le dossier du Dictaphone change, et en filet de sécurité toutes les 5 minutes et à l'ouverture de session.

Le **premier passage est l'amorçage** : tous les mémos déjà présents sont marqués ignorés, et aucune note n'est écrite. Seuls les mémos enregistrés ensuite deviennent des notes. Pour un ancien mémo, voir `traiter` plus bas.

## Au quotidien

```bash
~/Applications/Vocal.app/Contents/MacOS/Vocal état
tail ~/Library/Logs/Vocal/vocal.log
```

`état` liste les mémos traités, en attente, sans parole et en échec, avec les derniers passages. Le journal ne contient jamais le texte d'un mémo ni une réponse du LLM.

Pour traiter un mémo précis, même ancien ou ignoré à l'amorçage, par son titre dans le Dictaphone ou son nom de fichier :

```bash
~/Applications/Vocal.app/Contents/MacOS/Vocal traiter "Titre du mémo"
```

Un mémo déjà traité ne l'est de nouveau qu'avec `--encore`.

## La note produite

```markdown
---
type: note-vocale
date: 2026-11-11
source: vocal
statut: à traiter
duree: "0:14"
memo: "Titre du mémo dans le Dictaphone"
appareil: watch
llm: "minimax/MiniMax-M3.1-Flash"
---

# Titre rédigé par le LLM

## Résumé

## Texte nettoyé

## Transcription brute
```

- Nom de fichier : `AAAA-MM-JJ HHhMM - Vocal - <titre>.md`, à la date et l'heure de l'enregistrement.
- Sans LLM, ou s'il ne répond pas, la note est quand même écrite, avec le titre « Vocal sans titre » et la seule transcription brute.
- La transcription brute n'est jamais modifiée : elle reste la trace fidèle de la reconnaissance vocale.
- Le frontmatter est toujours rempli par Vocal, jamais par le LLM.

## Comportements à connaître

- **Stabilité** : un mémo est traité quand sa taille n'a pas changé pendant 12 secondes.
- **Échecs** : une transcription en échec est réessayée aux passages suivants ; au troisième échec, une note « Vocal transcription impossible » le signale. Un mémo sans aucune parole, comme un appui involontaire sur la Watch, est écarté sans note au troisième essai.
- **Supprimés récemment** : un mémo placé dans la corbeille du Dictaphone n'est pas traité ; récupéré, il l'est.
- **Base du Dictaphone** : Vocal en lit une copie, pour le titre et la corbeille, sans jamais toucher à l'original. Son schéma n'est pas documenté par Apple : si elle change, Vocal continue sans elle. Détails dans [docs/base-dictaphone.md](docs/base-dictaphone.md).
- **Obsidian Sync** ne pousse une note que si Obsidian tourne. Après avoir écrit une note, Vocal lance Obsidian caché s'il est installé et fermé. Obsidian rouvre les coffres ouverts à sa dernière fermeture : gardez-y le coffre de votre inbox.

## Confidentialité

- L'audio ne quitte jamais le Mac : la transcription est locale.
- Sans `model`, rien ne part sur le réseau. Avec un LLM, seul le texte transcrit lui est envoyé ; un modèle local le garde chez vous.
- Les clés d'API restent dans le trousseau, jamais dans un fichier, un argument ou un journal.

## Désinstaller

```bash
launchctl bootout gui/$(id -u)/com.votrenom.vocal
```

Puis mettez à la Corbeille `~/Library/LaunchAgents/com.votrenom.vocal.plist`, `~/Applications/Vocal.app` (et retirez-la de l'Accès complet au disque), et au besoin `~/Library/Application Support/Vocal` (l'état), `~/Library/Logs/Vocal` et `~/.config/vocal`. L'entrée du trousseau se retire dans Trousseaux d'accès. Vos notes et vos mémos ne sont jamais touchés.

## Développement

```text
Sources/
├── VocalCore/    # domaine : passage, état SQLite, note, réglages, base du Dictaphone
├── VocalSpeech/  # transcription Apple (SpeechAnalyzer)
├── VocalLLM/     # rédacteur LLM (openai-compatible, anthropic) et trousseau
└── Vocal/        # ligne de commande
Tests/            # tests Swift Testing, audio de synthèse fabriqué par scripts/make-fixtures.sh
```

```bash
swift test
VOCAL_TEST_INSTALLER_MODELE=1 swift test   # inclut la transcription Apple réelle
```

Les tests n'utilisent que de l'audio de synthèse et un trousseau factice.

## Licence

MIT, voir [LICENSE](LICENSE).
