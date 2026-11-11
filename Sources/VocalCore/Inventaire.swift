import Foundation
import SQLite3

/// Inventaire du dossier des enregistrements du Dictaphone, pour la commande `observer`.
/// Le rapport décrit la structure et compte ; il ne contient jamais un titre, un nom de fichier
/// de mémo, un nom de sous-dossier ni un chemin de la base.
public struct Inventaire: Sendable {
    public let texte: String

    public static func dresser(_ dossier: URL) async -> Inventaire {
        var lignes: [String] = []
        let fm = FileManager.default
        do {
            _ = try fm.contentsOfDirectory(atPath: dossier.path)
        } catch {
            lignes.append("lecture du dossier : refusée ou impossible (code \((error as NSError).code))")
            return Inventaire(texte: lignes.joined(separator: "\n") + "\n")
        }
        lignes.append("lecture du dossier : autorisée")

        var audio: [String: Int] = [:], autres: [String: Int] = [:]
        var icloud = 0
        var sousDossiers: [(forme: String, audio: Int)] = []
        var caches: [String] = []
        /// Parcourt un dossier ; rend le nombre de fichiers audio qu'il contient, sous-dossiers compris.
        func parcourir(_ courant: URL) -> Int {
            var nbAudio = 0
            for nom in ((try? fm.contentsOfDirectory(atPath: courant.path)) ?? []).sorted() {
                let url = courant.appendingPathComponent(nom)
                var estDossier: ObjCBool = false
                fm.fileExists(atPath: url.path, isDirectory: &estDossier)
                if nom.hasSuffix(".icloud") { icloud += 1 }
                if nom.hasPrefix(".") { caches.append(forme(nom)); continue }
                if estDossier.boolValue {
                    let index = sousDossiers.count
                    sousDossiers.append((forme(nom), 0))
                    let n = parcourir(url)
                    sousDossiers[index].audio = n
                    nbAudio += n
                    continue
                }
                let ext = url.pathExtension.lowercased()
                if ["m4a", "qta"].contains(ext) { audio[ext, default: 0] += 1; nbAudio += 1 }
                else { autres[ext.isEmpty ? "sans extension" : ext, default: 0] += 1 }
            }
            return nbAudio
        }
        let audioTotal = parcourir(dossier)
        lignes.append("fichiers audio : " + decompte(audio, ordre: ["m4a", "qta"]))
        lignes.append("remplacements iCloud : \(icloud)")
        lignes.append("sous-dossiers visibles : \(sousDossiers.count)")
        for (i, d) in sousDossiers.enumerated() {
            lignes.append("sous-dossier \(i + 1) (forme \(d.forme)) : \(d.audio) fichier(s) audio")
        }
        lignes.append("fichiers audio à la racine : \(audioTotal - sousDossiers.map(\.audio).reduce(0, +))")
        lignes.append("éléments cachés : \(caches.count)")
        for (i, f) in caches.sorted().enumerated() { lignes.append("élément caché \(i + 1) : forme \(f)") }
        lignes.append("autres fichiers : " + decompte(autres, ordre: autres.keys.sorted()))

        let base = dossier.appendingPathComponent("CloudRecordings.db")
        if fm.fileExists(atPath: base.path) {
            let (description, enregistrements) = BaseDictaphone.decrire(base, dossier: dossier)
            lignes += description
            lignes += await recoupements(enregistrements)
        } else {
            lignes.append("base CloudRecordings.db : absente")
        }
        lignes.append(lectureParLePassage(dossier))
        return Inventaire(texte: lignes.joined(separator: "\n") + "\n")
    }

    /// Recoupe la base avec les fichiers présents, et décrit les absents. Aucun contenu n'est recopié.
    static func recoupements(_ enregistrements: [BaseDictaphone.Enregistrement]) async -> [String] {
        guard !enregistrements.isEmpty else { return [] }
        var titres = (egaux: 0, comparables: 0), ids = (egaux: 0, comparables: 0)
        for e in enregistrements where e.present {
            guard let memo = try? await Memo.lire(e.fichier, fuseau: .current) else { continue }
            if let t = memo.titreInscrit, let base = e.titre { titres.comparables += 1; if t == base { titres.egaux += 1 } }
            if let i = memo.identifiant, let base = e.identifiant { ids.comparables += 1; if i == base { ids.egaux += 1 } }
        }
        let absents = enregistrements.filter { !$0.present }
        return [
            "ZENCRYPTEDTITLE égal au titre inscrit dans le fichier : \(titres.egaux) sur \(titres.comparables)",
            "ZUNIQUEID égal à l'identifiant inscrit dans le fichier : \(ids.egaux) sur \(ids.comparables)",
            "fichiers absents : \(absents.count) (ZEVICTIONDATE renseignée : \(absents.filter(\.evince).count) ; ZFLAGS : "
                + BaseDictaphone.repartition(absents.map(\.drapeaux)) + ")",
        ]
    }

    /// Fichier audio visible (`.m4a` ou `.qta`, hors dossiers cachés et remplacements iCloud)
    /// modifié en dernier, en parcourant les sous-dossiers.
    public static func dernierMemo(_ dossier: URL) -> URL? {
        let fm = FileManager.default
        var plusRecent: (URL, Date)?
        var aVisiter = [dossier]
        while let courant = aVisiter.popLast() {
            for nom in (try? fm.contentsOfDirectory(atPath: courant.path)) ?? [] where !nom.hasPrefix(".") {
                let url = courant.appendingPathComponent(nom)
                let valeurs = try? url.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey])
                if valeurs?.isDirectory == true { aVisiter.append(url); continue }
                guard ["m4a", "qta"].contains(url.pathExtension.lowercased()),
                      let date = valeurs?.contentModificationDate else { continue }
                if plusRecent == nil || date > plusRecent!.1 { plusRecent = (url, date) }
            }
        }
        return plusRecent?.0
    }

    /// Ce que le passage tire de la base, avec le lecteur qu'il utilise vraiment : des comptes seulement.
    static func lectureParLePassage(_ dossier: URL) -> String {
        let debut = "lecture de la base par le passage : "
        let fiches: [String: FicheDictaphone]
        switch CatalogueDictaphone.lire(dossier, copies: FileManager.default.temporaryDirectory) {
        case let .lue(f): fiches = f
        case let .ecart(raison): return debut + "base \(raison), le passage continue sans elle"
        }
        let presents = ((try? Releve.memos(dossier))?.fichiers ?? []).map(\.nom)
        let avecFiche = presents.filter { fiches[$0] != nil }
        return debut + "\(fiches.count) fiche(s), \(fiches.values.count { $0.titre != nil }) avec titre, "
            + "\(fiches.values.count(where: \.supprime)) dans « Supprimés récemment » ; \(presents.count) mémo(s) audio présent(s) : "
            + "\(avecFiche.count) avec fiche, \(presents.count - avecFiche.count) sans fiche, "
            + "\(avecFiche.count { fiches[$0]?.supprime == true }) supprimé(s)"
    }

    /// Forme d'une valeur, sans son contenu : chiffre → 9, majuscule → A, minuscule → a.
    static func forme(_ s: String) -> String {
        String(s.map { c in c.isNumber ? "9" : c.isUppercase ? "A" : c.isLetter ? "a" : c })
    }

    private static func decompte(_ d: [String: Int], ordre: [String]) -> String {
        let parts = ordre.compactMap { cle in d[cle].map { "\(cle) \($0)" } }
        return parts.isEmpty ? "aucun" : parts.joined(separator: ", ")
    }
}

/// Lecture seule de la base du Dictaphone, dont le schéma n'est pas documenté par Apple.
enum BaseDictaphone {
    /// Une ligne de ZCLOUDRECORDING, pour les recoupements. Ne sort jamais dans le rapport.
    struct Enregistrement {
        let fichier: URL
        let present: Bool
        let titre: String?
        let identifiant: String?
        let dossier: String?
        let drapeaux: String
        let evince: Bool
    }

    static func decrire(_ base: URL, dossier: URL) -> ([String], [Enregistrement]) {
        var db: OpaquePointer?
        guard sqlite3_open_v2(base.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return (["base CloudRecordings.db : ouverture impossible"], [])
        }
        defer { sqlite3_close(db) }
        let tables = requete(db, "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name")
            .map { $0[0] ?? "" }
        guard !tables.isEmpty else { return (["base CloudRecordings.db : lecture impossible ou vide"], []) }
        var lignes = ["base CloudRecordings.db : tables \(tables.joined(separator: ", "))"]
        guard tables.contains("ZCLOUDRECORDING") else { return (lignes + ["table ZCLOUDRECORDING : absente"], []) }

        let colonnes = requete(db, "PRAGMA table_info(ZCLOUDRECORDING)").map { ($0[1] ?? "?", $0[2] ?? "?") }
        lignes.append("colonnes ZCLOUDRECORDING : " + colonnes.map { "\($0.0) \($0.1)" }.joined(separator: ", "))
        let noms = Set(colonnes.map(\.0))

        let total = requete(db, "SELECT COUNT(*) FROM ZCLOUDRECORDING").first?[0] ?? "0"
        let supprimes = noms.contains("ZTRASHEDDATE")
            ? requete(db, "SELECT COUNT(*) FROM ZCLOUDRECORDING WHERE ZTRASHEDDATE IS NOT NULL").first?[0] ?? "0" : "colonne absente"
        lignes.append("enregistrements : \(total) (supprimés : \(supprimes))")

        for colonne in ["ZCUSTOMLABEL", "ZENCRYPTEDTITLE"] where noms.contains(colonne) {
            var texte = 0, date = 0, vide = 0
            for ligne in requete(db, "SELECT \(colonne) FROM ZCLOUDRECORDING") {
                guard let l = ligne[0], !l.isEmpty else { vide += 1; continue }
                if l.wholeMatch(of: /\d{4}-\d{2}-\d{2}.*/) != nil { date += 1 } else { texte += 1 }
            }
            lignes.append("\(colonne) : texte \(texte), forme de date \(date), vide \(vide)")
        }
        if noms.contains("ZCUSTOMLABEL") {
            let dates = requete(db, "SELECT ZCUSTOMLABEL FROM ZCLOUDRECORDING").compactMap { $0[0] }
                .filter { $0.wholeMatch(of: /\d{4}-\d{2}-\d{2}.*/) != nil }
            lignes.append("formes ZCUSTOMLABEL : " + formes(dates))
        }
        if noms.contains("ZUNIQUEID") {
            let ids = requete(db, "SELECT ZUNIQUEID FROM ZCLOUDRECORDING").map { $0[0] ?? "" }
            let uuids = ids.filter { UUID(uuidString: $0) != nil }.count
            lignes.append("ZUNIQUEID : forme UUID \(uuids) sur \(ids.count)")
        }
        for (colonne, libelle) in [("ZFOLDER", "ZFOLDER renseigné"), ("ZEVICTIONDATE", "ZEVICTIONDATE renseignée")] where noms.contains(colonne) {
            let n = requete(db, "SELECT COUNT(*) FROM ZCLOUDRECORDING WHERE \(colonne) IS NOT NULL").first?[0] ?? "0"
            lignes.append("\(libelle) : \(n ?? "0")")
        }
        if noms.contains("ZFLAGS") {
            let valeurs = requete(db, "SELECT ZFLAGS, COUNT(*) FROM ZCLOUDRECORDING GROUP BY ZFLAGS ORDER BY ZFLAGS")
            lignes.append("ZFLAGS : " + valeurs.map { "\($0[0] ?? "nul") × \($0[1] ?? "0")" }.joined(separator: ", "))
        }
        if noms.contains("ZFLAGS") {
            var bits: [Int: Int] = [:]
            for l in requete(db, "SELECT ZFLAGS FROM ZCLOUDRECORDING") {
                guard let v = l[0].flatMap(Int.init) else { continue }
                for b in 0..<63 where v & (1 << b) != 0 { bits[1 << b, default: 0] += 1 }
            }
            lignes.append("bits de ZFLAGS : " + (bits.isEmpty ? "aucun" : bits.sorted { $0.key < $1.key }.map { "\($0.key) × \($0.value)" }.joined(separator: ", ")))
        }
        let entites = tables.contains("Z_PRIMARYKEY")
            ? Dictionary(requete(db, "SELECT Z_ENT, Z_NAME, Z_MAX FROM Z_PRIMARYKEY ORDER BY Z_ENT").map { ($0[0] ?? "?", ($0[1] ?? "?", $0[2] ?? "?")) },
                         uniquingKeysWith: { a, _ in a })
            : [:]
        if noms.contains("Z_ENT") {
            let r = requete(db, "SELECT Z_ENT, COUNT(*) FROM ZCLOUDRECORDING GROUP BY Z_ENT ORDER BY Z_ENT")
            lignes.append("Z_ENT : " + r.map { "\($0[0] ?? "nul") \(entites[$0[0] ?? ""]?.0 ?? "?") × \($0[1] ?? "0")" }.joined(separator: ", "))
        } else {
            lignes.append("Z_ENT : colonne absente")
        }
        if !entites.isEmpty {
            lignes.append("entités (Z_PRIMARYKEY) : " + entites.sorted { (Int($0.key) ?? 0) < (Int($1.key) ?? 0) }
                .map { "\($0.key) \($0.value.0) (max \($0.value.1))" }.joined(separator: ", "))
        }
        if noms.contains("ZPATH") {
            var relatif = 0, absolu = 0, present = 0
            for ligne in requete(db, "SELECT ZPATH FROM ZCLOUDRECORDING") {
                guard let p = ligne[0], !p.isEmpty else { continue }
                let url = p.hasPrefix("/") ? URL(fileURLWithPath: p) : dossier.appendingPathComponent(p)
                if p.hasPrefix("/") { absolu += 1 } else { relatif += 1 }
                if FileManager.default.fileExists(atPath: url.path) { present += 1 }
            }
            lignes.append("ZPATH : relatif \(relatif), absolu \(absolu), fichier présent \(present)")
            lignes.append("formes ZPATH : " + formes(requete(db, "SELECT ZPATH FROM ZCLOUDRECORDING").compactMap { $0[0] }))
        }
        // Lignes pour les recoupements : une colonne absente devient NULL.
        func col(_ c: String) -> String { noms.contains(c) ? c : "NULL" }
        let enregistrements: [Enregistrement] = noms.contains("ZPATH") ? requete(db, """
            SELECT ZPATH, \(col("ZENCRYPTEDTITLE")), \(col("ZUNIQUEID")), \(col("ZFOLDER")), \(col("ZFLAGS")), \(col("ZEVICTIONDATE"))
            FROM ZCLOUDRECORDING
            """).compactMap { l in
            guard let p = l[0], !p.isEmpty else { return nil }
            let url = p.hasPrefix("/") ? URL(fileURLWithPath: p) : dossier.appendingPathComponent(p)
            return Enregistrement(fichier: url, present: FileManager.default.fileExists(atPath: url.path),
                                  titre: l[1], identifiant: l[2], dossier: l[3], drapeaux: l[4] ?? "nul", evince: l[5] != nil)
        } : []

        if tables.contains("ZRECORDING") {
            let n = requete(db, "SELECT COUNT(*) FROM ZRECORDING").first?[0] ?? "0"
            let cols = requete(db, "PRAGMA table_info(ZRECORDING)").map { "\($0[1] ?? "?") \($0[2] ?? "?")" }
            lignes.append("ZRECORDING (table) : \(n ?? "0") ligne(s) ; colonnes \(cols.joined(separator: ", "))")
        }
        if tables.contains("ZFOLDER") {
            let n = requete(db, "SELECT COUNT(*) FROM ZFOLDER").first?[0] ?? "0"
            let infos = requete(db, "PRAGMA table_info(ZFOLDER)")
            let cols = infos.map { "\($0[1] ?? "?") \($0[2] ?? "?")" }
            lignes.append("ZFOLDER (table) : \(n ?? "0") ligne(s) ; colonnes \(cols.joined(separator: ", "))")
            let colsDossier = Set(infos.compactMap { $0[1] })
            func colD(_ c: String) -> String { colsDossier.contains(c) ? c : "NULL" }
            let dossiers = requete(db, "SELECT Z_PK, \(colD("ZENCRYPTEDNAME")), \(colD("ZCOUNTOFRECORDINGS")) FROM ZFOLDER ORDER BY Z_PK")
            for (i, d) in dossiers.enumerated() {
                let rattaches = enregistrements.filter { $0.dossier == d[0] }
                lignes.append("dossier \(i + 1) (forme \(Inventaire.forme(d[1] ?? ""))) : ZCOUNTOFRECORDINGS \(d[2] ?? "?"), "
                              + "mémos rattachés \(rattaches.count), ZFLAGS : \(repartition(rattaches.map(\.drapeaux)))")
            }
        }
        return (lignes, enregistrements)
    }

    /// Répartition de valeurs, triées : `0 × 2, 4 × 1`.
    static func repartition(_ valeurs: [String]) -> String {
        let compte = Dictionary(valeurs.map { ($0, 1) }, uniquingKeysWith: +)
        let tri = compte.sorted { (Int($0.key) ?? .max, $0.key) < (Int($1.key) ?? .max, $1.key) }
        return tri.isEmpty ? "aucune" : tri.map { "\($0.key) × \($0.value)" }.joined(separator: ", ")
    }

    /// Les cinq formes les plus fréquentes, avec leur nombre.
    static func formes(_ valeurs: [String]) -> String {
        let compte = Dictionary(valeurs.map { (Inventaire.forme($0), 1) }, uniquingKeysWith: +)
        let tri = compte.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(5)
        return tri.isEmpty ? "aucune" : tri.map { "\($0.key) × \($0.value)" }.joined(separator: ", ")
    }

    /// Exécute une requête et rend les lignes, chaque colonne en texte ou nil.
    static func requete(_ db: OpaquePointer?, _ sql: String) -> [[String?]] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var lignes: [[String?]] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            lignes.append((0..<sqlite3_column_count(stmt)).map { i in
                sqlite3_column_text(stmt, i).map { String(cString: $0) }
            })
        }
        return lignes
    }
}
