import Darwin
import Foundation

/// Écrit une note sans jamais écraser un fichier existant ni laisser de fichier partiel visible.
/// Le texte va dans un fichier caché du dossier cible (`preparer`), puis il est renommé de façon exclusive
/// (`publier`, `renamex_np` avec `RENAME_EXCL`) ; si le nom est pris, on essaie ` (2)`, ` (3)`, etc.
/// Les erreurs citent le dossier, jamais le nom de la note, qui vient du titre.
enum EcritureNote {
    static let prefixeTemporaire = ".vocal-"
    static let suffixeTemporaire = ".tmp"

    static func ecrire(_ texte: String, nomDeBase: String, dans dossier: URL) throws -> URL {
        let temporaire = try preparer(texte, dans: dossier)
        do { return try publier(temporaire, nomDeBase: nomDeBase, dans: dossier) } catch {
            try? FileManager.default.removeItem(at: temporaire)
            throw error
        }
    }

    /// Écrit le texte dans un fichier caché du dossier et le synchronise sur le disque.
    static func preparer(_ texte: String, dans dossier: URL) throws -> URL {
        let temporaire = dossier.appendingPathComponent("\(prefixeTemporaire)\(UUID().uuidString)\(suffixeTemporaire)")
        guard FileManager.default.createFile(atPath: temporaire.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: dossier.path])
        }
        do {
            let poignee = try FileHandle(forWritingTo: temporaire)
            defer { try? poignee.close() }
            try poignee.write(contentsOf: Data(texte.utf8))
            try poignee.synchronize()
        } catch {
            try? FileManager.default.removeItem(at: temporaire)
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: dossier.path])
        }
        return temporaire
    }

    /// Renomme le fichier préparé en `<nomDeBase>.md`, ou avec le premier suffixe libre.
    static func publier(_ temporaire: URL, nomDeBase: String, dans dossier: URL) throws -> URL {
        for rang in 1... {
            let nom = rang == 1 ? "\(nomDeBase).md" : "\(nomDeBase) (\(rang)).md"
            let cible = dossier.appendingPathComponent(nom)
            if renamex_np(temporaire.path, cible.path, UInt32(RENAME_EXCL)) == 0 { return cible }
            guard errno == EEXIST else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: dossier.path,
                                                             NSUnderlyingErrorKey: POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)])
            }
        }
        fatalError("inaccessible")
    }
}
