# Ce que Vocal sait du Dictaphone

Constats faits sous macOS 27 sur un Mac qui synchronise ses mémos par iCloud. Apple ne documente ni ce dossier ni cette base : ils peuvent changer avec une mise à jour.

## Le dossier

- `~/Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings`, protégé par macOS. Sans Accès complet au disque, sa lecture échoue (code 257), sans aucune demande à l'écran, y compris sous launchd. L'accès accordé à une app signée survit à ses mises à jour signées avec le même certificat.
- Un fichier par mémo, à la racine : `AAAAMMJJ HHMMSS-XXXXXXXX.m4a`, ou `.qta` pour l'audio spatial de l'iPhone. Le nom contient la date et l'heure locales de l'enregistrement.
- Pour un `.qta`, AVAudioFile lit la piste stéréo AAC, la seule activée.
- L'encodeur inscrit dans le fichier dit l'appareil : `com.apple.VoiceMemos (Watch …)`, `(iPhone …)` ou `(iPad …)`.
- Un mémo enregistré sur la Watch arrive sur le Mac une vingtaine de secondes après la fin de l'enregistrement.
- Un audio pas encore téléchargé peut n'être qu'un remplacement iCloud `.<nom>.icloud`.

## La base `CloudRecordings.db`

- Base Core Data synchronisée par CloudKit, en mode WAL, dans le même dossier.
- Table `ZCLOUDRECORDING`, une ligne par mémo :
  - `ZPATH` : le nom du fichier, relatif au dossier. C'est la clé la plus stable observée, et Vocal s'en sert comme identité d'un mémo.
  - `ZENCRYPTEDTITLE` : le titre affiché dans le Dictaphone, en clair malgré son nom. Il fait foi quand il diffère du titre inscrit dans le fichier, par exemple après un renommage.
  - `ZCUSTOMLABEL` : une date ISO, pas un titre.
  - `ZEVICTIONDATE` : renseignée quand le mémo est dans « Supprimés récemment », vide sinon. Le Dictaphone purge seul les mémos expirés, de la base et du disque.
  - `ZUNIQUEID` : un UUID, qui ne correspond pas toujours à l'identifiant `voice-memo-uuid` inscrit dans le fichier.
  - `ZDATE` et `ZDURATION` : date (secondes depuis 2001) et durée ; Vocal prend celles du fichier.
- Ouvrir la base en place, même en lecture seule, écrit dans son index partagé `-shm`. Vocal copie donc la base et son journal `-wal` dans son propre dossier, et lit la copie.
