#!/bin/bash
# Génère dans build/ la tâche launchd de Vocal : un passage dès que le dossier du Dictaphone change, et en filet
# de sécurité toutes les 5 minutes et à l'ouverture de session,
# lancé directement depuis l'app installée dans ~/Applications. Ne charge rien : l'installation reste un geste de
# l'utilisateur. Le fichier est écrit sur place, donc sans attribut de quarantaine.
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/identite.sh
label="$VOCAL_BUNDLE_ID"
app="$HOME/Applications/Vocal.app"
logs="$HOME/Library/Logs/Vocal"
enregistrements="$HOME/Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings"
mkdir -p build
plist="build/$label.plist"
cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$label</string>
	<key>ProgramArguments</key>
	<array>
		<string>$app/Contents/MacOS/Vocal</string>
		<string>passage</string>
	</array>
	<key>AssociatedBundleIdentifiers</key>
	<array>
		<string>$VOCAL_BUNDLE_ID</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>StartInterval</key>
	<integer>300</integer>
	<key>WatchPaths</key>
	<array>
		<string>$enregistrements</string>
	</array>
	<key>StandardOutPath</key>
	<string>$logs/launchd.log</string>
	<key>StandardErrorPath</key>
	<string>$logs/launchd.log</string>
</dict>
</plist>
PLIST
plutil -lint "$plist" >&2
echo "$PWD/$plist"
