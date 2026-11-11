import Foundation
import SQLite3

/// Schéma de `ZCLOUDRECORDING` relevé sur un Mac sous macOS 27 (colonnes et types seulement).
let schemaReleve = """
    CREATE TABLE ZCLOUDRECORDING (Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZAUDIOFUTUREFLAGS INTEGER,
    ZFLAGS INTEGER, ZSHAREDFLAGS INTEGER, ZSILENCEREMOVERENABLED INTEGER, ZSKIPSILENCEENABLED INTEGER,
    ZSTUDIOMIXENABLED INTEGER, ZFOLDER INTEGER, ZDATE TIMESTAMP, ZDURATION FLOAT, ZEVICTIONDATE TIMESTAMP,
    ZLOCALDURATION FLOAT, ZMTLAYERMIX FLOAT, ZPLAYBACKPOSITION FLOAT, ZPLAYBACKRATE FLOAT, ZPLAYBACKSPEED FLOAT,
    ZSTUDIOMIXLEVEL FLOAT, ZCUSTOMLABEL VARCHAR, ZCUSTOMLABELFORSORTING VARCHAR, ZENCRYPTEDTITLE VARCHAR,
    ZPATH VARCHAR, ZUNIQUEID VARCHAR, ZAUDIOFUTUREUUIDS BLOB, ZAUDIODIGEST BLOB, ZAUDIOFUTURE BLOB,
    ZMTAUDIOFUTURE BLOB, ZVERSIONEDAUDIOFUTURE BLOB)
    """

/// Une ligne de la base fabriquée : fichier, titre affiché, et date de suppression (secondes depuis 2001).
struct LigneDictaphone {
    var fichier: String?
    var titre: String?
    var supprimeLe: Double? = nil
}

/// Fabrique `CloudRecordings.db` dans un dossier des enregistrements, en mode WAL comme la vraie base.
/// `schema` permet de fabriquer une base au schéma différent ; les colonnes absentes ne sont pas remplies.
func fabriquerBaseDictaphone(dans dossier: URL, _ lignes: [LigneDictaphone], schema: String = schemaReleve) throws {
    var db: OpaquePointer?
    let fichier = dossier.appendingPathComponent("CloudRecordings.db")
    guard sqlite3_open(fichier.path, &db) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
    defer { sqlite3_close(db) }
    func executer(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "fabrication", code: 1, userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
        }
    }
    func texte(_ s: String?) -> String { s.map { "'" + $0.replacingOccurrences(of: "'", with: "''") + "'" } ?? "NULL" }
    try executer("PRAGMA journal_mode = WAL")
    try executer(schema)
    for l in lignes {
        // Un schéma différent peut manquer de colonnes : la ligne est alors laissée de côté.
        try? executer("INSERT INTO ZCLOUDRECORDING (ZPATH, ZENCRYPTEDTITLE, ZEVICTIONDATE, ZUNIQUEID) VALUES "
                      + "(\(texte(l.fichier)), \(texte(l.titre)), \(l.supprimeLe.map { "\($0)" } ?? "NULL"), '\(UUID().uuidString)')")
    }
}

/// Modifie la date de suppression d'un mémo dans la base fabriquée, comme le Dictaphone le fait.
func marquerSupprime(dans dossier: URL, _ fichier: String, le date: Double?) throws {
    var db: OpaquePointer?
    guard sqlite3_open(dossier.appendingPathComponent("CloudRecordings.db").path, &db) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
    defer { sqlite3_close(db) }
    let sql = "UPDATE ZCLOUDRECORDING SET ZEVICTIONDATE = \(date.map { "\($0)" } ?? "NULL") "
        + "WHERE ZPATH = '\(fichier.replacingOccurrences(of: "'", with: "''"))'"
    guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
}
