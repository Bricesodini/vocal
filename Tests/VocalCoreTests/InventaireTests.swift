import Foundation
import SQLite3
import Testing
import VocalCore

@Suite("Commande observer")
struct InventaireTests {
    /// Fabrique un faux dossier d'enregistrements du Dictaphone.
    func dossierDictaphone() throws -> URL {
        let racine = try dossierTemporaire()
        let fm = FileManager.default
        try fm.copyItem(at: fixtures.appendingPathComponent("watch.m4a"), to: racine.appendingPathComponent("20261009 132121-7EB013BF.m4a"))
        try fm.copyItem(at: fixtures.appendingPathComponent("iphone.qta"), to: racine.appendingPathComponent("20260702 191614-C4BBE1A5.qta"))
        try fm.createDirectory(at: racine.appendingPathComponent("Sous dossier"), withIntermediateDirectories: true)
        try fm.copyItem(at: fixtures.appendingPathComponent("watch.m4a"), to: racine.appendingPathComponent("Sous dossier/20261101 080000-11111111.m4a"))
        try fm.createDirectory(at: racine.appendingPathComponent(".Trash"), withIntermediateDirectories: true)
        try Data().write(to: racine.appendingPathComponent(".20261105 090000-22222222.m4a.icloud"))
        try Data().write(to: racine.appendingPathComponent("notes.plist"))

        var db: OpaquePointer?
        #expect(sqlite3_open(racine.appendingPathComponent("CloudRecordings.db").path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        let sql = """
        CREATE TABLE ZCLOUDRECORDING (Z_PK INTEGER PRIMARY KEY, ZCUSTOMLABEL VARCHAR, ZDATE TIMESTAMP,
          ZDURATION FLOAT, ZPATH VARCHAR, ZTRASHEDDATE TIMESTAMP, ZENCRYPTEDTITLE VARCHAR, ZUNIQUEID VARCHAR,
          ZFOLDER INTEGER, ZEVICTIONDATE TIMESTAMP, ZFLAGS INTEGER);
        CREATE TABLE ZFOLDER (Z_PK INTEGER PRIMARY KEY, ZENCRYPTEDNAME VARCHAR);
        CREATE TABLE Z_PRIMARYKEY (Z_ENT INTEGER PRIMARY KEY, Z_NAME VARCHAR, Z_SUPER INTEGER, Z_MAX INTEGER);
        INSERT INTO Z_PRIMARYKEY VALUES (1, 'CloudRecording', 0, 4);
        INSERT INTO Z_PRIMARYKEY VALUES (2, 'Folder', 0, 1);
        CREATE TABLE ZRECORDING (Z_PK INTEGER PRIMARY KEY, ZTITLE VARCHAR);
        INSERT INTO ZRECORDING VALUES (1, 'Titre caché');
        INSERT INTO ZFOLDER VALUES (1, 'Mes idées secrètes');
        INSERT INTO ZCLOUDRECORDING VALUES (1, 'Rue Secrète 12', 773000000, 76.0, '20260702 191614-C4BBE1A5.qta', NULL,
          'Rue des Essais 12', 'C4BBE1A5-0000-4000-8000-000000000001', NULL, NULL, 0);
        INSERT INTO ZCLOUDRECORDING VALUES (2, '2026-10-09T13:21:21+02:00', 781000000, 8.1, '20261009 132121-7EB013BF.m4a', NULL,
          'Test Watch', '7EB013BF-637F-4B28-974C-E13B3CBD3E67', 1, NULL, 0);
        INSERT INTO ZCLOUDRECORDING VALUES (3, 'Idée privée', 782000000, 12.0, '/chemin/absolu/20260101 000000-33333333.m4a', 782500000,
          NULL, 'pas-un-uuid', NULL, NULL, 4);
        INSERT INTO ZCLOUDRECORDING VALUES (4, NULL, 783000000, 5.0, '20261105 090000-22222222.m4a', NULL,
          '2026-11-05 09:00', '22222222-0000-4000-8000-000000000004', NULL, 783100000, 4);
        """
        #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
        return racine
    }

    @Test("le rapport décrit le dossier et la base, sans aucun titre de mémo")
    func rapport() async throws {
        let racine = try dossierDictaphone()

        let rapport = await Inventaire.dresser(racine).texte

        #expect(rapport.contains("lecture du dossier : autorisée"))
        #expect(rapport.contains("fichiers audio : m4a 2, qta 1"))
        #expect(rapport.contains("remplacements iCloud : 1"))
        #expect(rapport.contains("sous-dossiers visibles : 1"))
        #expect(rapport.contains("éléments cachés : 2"))
        #expect(rapport.contains("autres fichiers : db 1, plist 1"))
        #expect(rapport.contains("base CloudRecordings.db : tables ZCLOUDRECORDING, ZFOLDER"))
        #expect(rapport.contains("colonnes ZCLOUDRECORDING : Z_PK INTEGER, ZCUSTOMLABEL VARCHAR, ZDATE TIMESTAMP, ZDURATION FLOAT, ZPATH VARCHAR, ZTRASHEDDATE TIMESTAMP"))
        #expect(rapport.contains("enregistrements : 4 (supprimés : 1)"))
        #expect(rapport.contains("ZCUSTOMLABEL : texte 2, forme de date 1, vide 1"))
        #expect(rapport.contains("ZPATH : relatif 3, absolu 1, fichier présent 2"))
        #expect(rapport.contains("ZENCRYPTEDTITLE : texte 2, forme de date 1, vide 1"))
        #expect(rapport.contains("ZUNIQUEID : forme UUID 3 sur 4"))
        #expect(rapport.contains("ZFOLDER renseigné : 1"))
        #expect(rapport.contains("ZEVICTIONDATE renseignée : 1"))
        #expect(rapport.contains("ZFLAGS : 0 × 2, 4 × 2"))
        #expect(rapport.contains("bits de ZFLAGS : 4 × 2"))
        #expect(rapport.contains("Z_ENT : colonne absente"))
        #expect(rapport.contains("entités (Z_PRIMARYKEY) : 1 CloudRecording (max 4), 2 Folder (max 1)"))
        #expect(rapport.contains("ZRECORDING (table) : 1 ligne(s) ; colonnes Z_PK INTEGER, ZTITLE VARCHAR"))
        #expect(rapport.contains("ZFOLDER (table) : 1 ligne(s) ; colonnes Z_PK INTEGER, ZENCRYPTEDNAME VARCHAR"))
        #expect(rapport.contains("formes ZCUSTOMLABEL : 9999-99-99A99:99:99+99:99 × 1"))
        #expect(rapport.contains("99999999 999999-9AA999AA.a9a × 1"))
        #expect(rapport.contains("99999999 999999-A9AAA9A9.aaa × 1"))
        #expect(rapport.contains("sous-dossier 1 (forme Aaaa aaaaaaa) : 1 fichier(s) audio"))
        #expect(rapport.contains("élément caché 2 : forme .Aaaaa"))
        #expect(rapport.contains("ZENCRYPTEDTITLE égal au titre inscrit dans le fichier : 1 sur 1"))
        #expect(rapport.contains("ZUNIQUEID égal à l'identifiant inscrit dans le fichier : 1 sur 1"))
        #expect(rapport.contains("fichiers absents : 2 (ZEVICTIONDATE renseignée : 1 ; ZFLAGS : 4 × 2)"))
        #expect(rapport.contains("dossier 1 (forme Aaa aaaaa aaaaaaaa) : ZCOUNTOFRECORDINGS ?, mémos rattachés 1, ZFLAGS : 0 × 1"))
        #expect(rapport.contains("lecture de la base par le passage : 4 fiche(s), 3 avec titre, 1 dans « Supprimés récemment » ; "
                                 + "3 mémo(s) audio présent(s) : 2 avec fiche, 1 sans fiche, 0 supprimé(s)"))
        for prive in ["Rue Secrète", "Rue des Essais", "Idée privée", "Sous dossier", "7EB013BF", "chemin/absolu", "Mes idées", "Test Watch", "Titre caché"] {
            #expect(!rapport.contains(prive), "le rapport contient « \(prive) »")
        }
    }

    @Test("un dossier illisible est signalé, sans erreur fatale")
    func dossierIllisible() async throws {
        let absent = try dossierTemporaire().appendingPathComponent("absent")

        let rapport = await Inventaire.dresser(absent).texte

        #expect(rapport.contains("lecture du dossier : refusée ou impossible"))
    }

    @Test("le mémo le plus récent est le fichier audio visible modifié en dernier")
    func dernierMemo() async throws {
        let racine = try dossierDictaphone()
        let fm = FileManager.default
        let date = { (iso: String) in ISO8601DateFormatter().date(from: iso)! }
        try fm.setAttributes([.modificationDate: date("2026-01-01T00:00:00Z")], ofItemAtPath: racine.appendingPathComponent("20261009 132121-7EB013BF.m4a").path)
        try fm.setAttributes([.modificationDate: date("2026-02-01T00:00:00Z")], ofItemAtPath: racine.appendingPathComponent("20260702 191614-C4BBE1A5.qta").path)
        try fm.setAttributes([.modificationDate: date("2026-03-01T00:00:00Z")], ofItemAtPath: racine.appendingPathComponent("Sous dossier/20261101 080000-11111111.m4a").path)
        try fm.setAttributes([.modificationDate: date("2026-04-01T00:00:00Z")], ofItemAtPath: racine.appendingPathComponent(".20261105 090000-22222222.m4a.icloud").path)

        #expect(Inventaire.dernierMemo(racine)?.lastPathComponent == "20261101 080000-11111111.m4a")
    }
}
