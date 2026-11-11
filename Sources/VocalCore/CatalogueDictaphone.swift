import Foundation
import SQLite3

/// Ce que la base du Dictaphone dit d'un mémo.
struct FicheDictaphone: Equatable {
    /// Titre affiché dans le Dictaphone (`ZENCRYPTEDTITLE`, en clair malgré son nom), s'il en a un.
    let titre: String?
    /// Vrai si le mémo est dans « Supprimés récemment » (`ZEVICTIONDATE` renseignée).
    let supprime: Bool
}

/// Base du Dictaphone, `CloudRecordings.db`. Vocal n'y touche jamais : il en copie la base et son journal `-wal`
/// dans un dossier à lui et lit la copie, car même une ouverture en lecture seule écrirait dans l'index `-shm`.
/// Son schéma n'est pas documenté par Apple : si elle manque, est illisible ou a changé, Vocal continue sans elle,
/// et l'écart est journalisé.
enum CatalogueDictaphone {
    static let nomDeFichier = "CloudRecordings.db"
    static let colonnes = ["ZPATH", "ZENCRYPTEDTITLE", "ZEVICTIONDATE"]

    enum Lecture {
        /// Fiches des mémos, par nom de fichier : la clé du mémo dans l'état.
        case lue([String: FicheDictaphone])
        /// La base n'a pas servi, pour cette raison, qui ne contient ni chemin ni contenu.
        case ecart(String)

        var fiches: [String: FicheDictaphone] {
            if case let .lue(f) = self { return f }
            return [:]
        }
    }

    /// Lit la base du dossier des enregistrements à travers une copie faite sous `copies`, retirée ensuite.
    static func lire(_ enregistrements: URL, copies: URL) -> Lecture {
        let fm = FileManager.default
        let fichier = enregistrements.appendingPathComponent(nomDeFichier)
        guard fm.fileExists(atPath: fichier.path) else { return .ecart("absente") }
        let dossier = copies.appendingPathComponent("dictaphone-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: dossier) }
        let copie = dossier.appendingPathComponent(nomDeFichier)
        do {
            try fm.createDirectory(at: dossier, withIntermediateDirectories: true)
            try fm.copyItem(at: fichier, to: copie)
            if fm.fileExists(atPath: fichier.path + "-wal") {
                try fm.copyItem(atPath: fichier.path + "-wal", toPath: copie.path + "-wal")
            }
        } catch {
            return .ecart("illisible (copie impossible, code \((error as NSError).code))")
        }
        return lireCopie(copie)
    }

    /// Lit une copie de la base, qui appartient à Vocal : SQLite peut y intégrer le journal `-wal` copié.
    private static func lireCopie(_ copie: URL) -> Lecture {
        var db: OpaquePointer?
        guard sqlite3_open_v2(copie.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            let code = sqlite3_extended_errcode(db)
            sqlite3_close(db)
            return .ecart("illisible (code \(code))")
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 2000)

        func requete(_ sql: String) -> [[String?]]? {
            var instruction: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &instruction, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(instruction) }
            var lignes: [[String?]] = []
            while true {
                switch sqlite3_step(instruction) {
                case SQLITE_ROW:
                    lignes.append((0..<sqlite3_column_count(instruction)).map { i in
                        sqlite3_column_text(instruction, i).map { String(cString: $0) }
                    })
                case SQLITE_DONE: return lignes
                default: return nil
                }
            }
        }

        guard let infos = requete("PRAGMA table_info(ZCLOUDRECORDING)") else {
            return .ecart("illisible (code \(sqlite3_extended_errcode(db)))")
        }
        let presentes = Set(infos.compactMap { $0.count > 1 ? $0[1] : nil })
        if presentes.isEmpty { return .ecart("schéma différent : table ZCLOUDRECORDING absente") }
        if let manquante = colonnes.first(where: { !presentes.contains($0) }) {
            return .ecart("schéma différent : colonne \(manquante) absente")
        }
        guard let lignes = requete("SELECT ZPATH, ZENCRYPTEDTITLE, ZEVICTIONDATE IS NOT NULL FROM ZCLOUDRECORDING") else {
            return .ecart("illisible (code \(sqlite3_extended_errcode(db)))")
        }
        var fiches: [String: FicheDictaphone] = [:]
        for l in lignes {
            guard let chemin = l[0], !chemin.isEmpty else { continue }
            let nom = (chemin as NSString).lastPathComponent
            let titre = l[1].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
            let fiche = FicheDictaphone(titre: titre, supprime: l[2] == "1")
            // Deux lignes pour un même fichier : celle qui n'est pas supprimée l'emporte.
            if let deja = fiches[nom], !deja.supprime { continue }
            fiches[nom] = fiche
        }
        return .lue(fiches)
    }
}
