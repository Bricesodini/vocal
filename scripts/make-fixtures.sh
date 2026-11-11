#!/bin/bash
# Fabrique les fichiers audio de synthèse des tests. Outil de développement seulement :
# ni Vocal ni ses tests n'appellent ffmpeg. Aucun mémo personnel n'entre dans le dépôt.
set -euo pipefail
cd "$(dirname "$0")/../Tests/Fixtures"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

say -v Thomas -o "$tmp/voix.aiff" "Bonjour, ceci est un mémo de test pour Vocal. Je parle du projet trame et du référencement."

tag() { swift "$root/scripts/tag-audio.swift" "$@"; }
root="$(cd ../.. && pwd)"

# Audio brut, sans métadonnées.
ffmpeg -loglevel error -y -fflags +bitexact -i "$tmp/voix.aiff" -ac 1 -ar 48000 -c:a aac -b:a 64k -map_metadata -1 -f ipod "$tmp/mono.m4a"
ffmpeg -loglevel error -y -fflags +bitexact -i "$tmp/voix.aiff" -ac 2 -ar 48000 -c:a aac -b:a 96k -map_metadata -1 -f mov "$tmp/stereo.mov"
ffmpeg -loglevel error -y -fflags +bitexact -f lavfi -i anullsrc=r=48000:cl=mono -t 30 -c:a aac -b:a 32k -map_metadata -1 -f ipod "$tmp/silence.m4a"

# Mémo Watch : m4a mono, sans titre.
tag "$tmp/mono.m4a" watch.m4a m4a "com.apple.VoiceMemos (Watch Version 27.0.1 (Build 24R365))" - 2026-10-09T11:21:21Z 7EB013BF-637F-4B28-974C-E13B3CBD3E67
# Mémo iPhone : conteneur QuickTime .qta, avec titre.
tag "$tmp/stereo.mov" "$tmp/iphone.mov" mov "com.apple.VoiceMemos (iPhone Version 26.5 (Build 23F77))" "Rue des Essais 12" 2026-07-02T17:16:15Z
mv "$tmp/iphone.mov" iphone.qta
# Mémo iPad de 30 s de silence, pour le contrôle de vraisemblance.
tag "$tmp/silence.m4a" silence-ipad.m4a m4a "com.apple.VoiceMemos (iPad Version 26.3 (Build 25D125))" Silence 2026-11-01T08:00:00Z
# Titre avec guillemets et barre oblique inverse, pour l'échappement du frontmatter.
tag "$tmp/mono.m4a" guillemets.m4a m4a "com.apple.VoiceMemos (iPhone Version 26.5 (Build 23F77))" 'Idée "folle" \ à tester' 2026-11-02T09:05:00Z
# Fichier sans aucune métadonnée.
cp "$tmp/mono.m4a" sans-meta.m4a

ls -la
