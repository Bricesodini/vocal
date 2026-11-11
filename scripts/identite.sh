# Identité de construction de Vocal, lue par build-app.sh et launchd-vocal.sh.
# - VOCAL_BUNDLE_ID : identifiant de l'app. macOS y attache l'Accès complet au disque et la réservation du modèle
#   de transcription : le garder stable d'une construction à l'autre.
# - VOCAL_SIGNATURE : certificat de signature du trousseau. « Apple Development » garde une identité stable aux yeux
#   de macOS ; « - » signe sans certificat, mais l'Accès complet au disque est alors à redonner après chaque construction.
# Un fichier scripts/identite.local, ignoré par Git, peut fixer ces deux valeurs pour une machine.
racine_identite="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$racine_identite/identite.local" ]; then . "$racine_identite/identite.local"; fi
: "${VOCAL_BUNDLE_ID:=com.example.vocal}"
: "${VOCAL_SIGNATURE:=Apple Development}"
