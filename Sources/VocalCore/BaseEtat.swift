import Foundation
import SQLite3

public enum ErreurEtat: Error, CustomStringConvertible {
    case base(String)

    public var description: String {
        switch self { case let .base(message): return "base d'état : \(message)" }
    }
}

/// Statut d'un mémo dans l'état de Vocal.
enum Statut: String {
    case vu, traite = "traité", ignore = "ignoré", echec = "échec"
    /// Aucune parole détectée après trois essais, par exemple un appui involontaire : pas de note.
    case sansParole = "sans parole"
}

/// Une ligne de l'état : ce que Vocal sait d'un mémo, repéré par son nom de fichier.
struct LigneMemo {
    let numero: Int64
    let fichier: String
    var statut: Statut
    var taille: Int64
    var modification: Double
    var observeLe: Double
    var tentatives: Int
    var note: String?
    var majLe: Double = 0
    /// Note en cours d'écriture : fichier temporaire dans l'inbox, nom de base visé et statut visé.
    /// Renseigné entre l'écriture du fichier temporaire et son renommage, pour reprendre après une coupure.
    var ecriture: Ecriture?

    struct Ecriture {
        let temporaire: String
        let nomDeBase: String
        let statut: Statut
    }
}

/// Un passage enregistré dans l'état.
struct LignePassage {
    let numero: Int64
    let debut: Double
    let amorces: Int
    let notes: Int
    let enAttente: Int
    let echecs: Int
}

/// Base SQLite de l'état, hors du vault. Une instance par passage, jamais partagée entre tâches.
final class BaseEtat {
    static let nomDeFichier = "etat.sqlite"
    private var db: OpaquePointer?

    /// Ouvre ou crée la base du dossier d'état.
    init(_ dossier: URL) throws {
        try ouvrir(dossier.appendingPathComponent(Self.nomDeFichier), SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        try executer("""
            CREATE TABLE IF NOT EXISTS memos (
              numero INTEGER PRIMARY KEY,
              fichier TEXT NOT NULL UNIQUE,
              statut TEXT NOT NULL,
              taille INTEGER NOT NULL DEFAULT 0,
              modification REAL NOT NULL DEFAULT 0,
              observe_le REAL NOT NULL DEFAULT 0,
              tentatives INTEGER NOT NULL DEFAULT 0,
              note TEXT,
              maj_le REAL NOT NULL,
              ecriture_temporaire TEXT,
              ecriture_nom TEXT,
              ecriture_statut TEXT);
            CREATE TABLE IF NOT EXISTS passages (
              numero INTEGER PRIMARY KEY,
              debut REAL NOT NULL,
              fin REAL NOT NULL,
              amorces INTEGER NOT NULL,
              notes INTEGER NOT NULL,
              en_attente INTEGER NOT NULL,
              echecs INTEGER NOT NULL);
            CREATE TABLE IF NOT EXISTS reglages (cle TEXT PRIMARY KEY, valeur TEXT NOT NULL);
            """)
    }

    /// Ouvre la base existante d'un dossier d'état en lecture seule, pour la commande `état`. Rend nil si elle n'existe pas.
    init?(lecture dossier: URL) throws {
        let fichier = dossier.appendingPathComponent(Self.nomDeFichier)
        guard FileManager.default.fileExists(atPath: fichier.path) else { return nil }
        try ouvrir(fichier, SQLITE_OPEN_READONLY)
    }

    deinit { sqlite3_close(db) }

    private func ouvrir(_ fichier: URL, _ drapeaux: Int32) throws {
        guard sqlite3_open_v2(fichier.path, &db, drapeaux, nil) == SQLITE_OK else {
            sqlite3_close(db)
            db = nil
            throw ErreurEtat.base("ouverture impossible")
        }
        // Un passage et la commande `état` peuvent lire la base en même temps.
        sqlite3_busy_timeout(db, 5000)
    }

    // MARK: Lecture

    func nombreDePassages() throws -> Int { Int(try lignes("SELECT COUNT(*) FROM passages").first?[0].entier ?? 0) }

    func compter(_ statut: Statut) throws -> Int {
        Int(try lignes("SELECT COUNT(*) FROM memos WHERE statut = ?", [.texte(statut.rawValue)]).first?[0].entier ?? 0)
    }

    /// Dossier des enregistrements sur lequel l'état a été amorcé.
    func dossierAmorce() throws -> String? {
        try lignes("SELECT valeur FROM reglages WHERE cle = 'enregistrements'").first?[0].texte
    }

    private static let colonnesMemo = """
        numero, fichier, statut, taille, modification, observe_le, tentatives, note, maj_le,
        ecriture_temporaire, ecriture_nom, ecriture_statut
        """

    func memos() throws -> [String: LigneMemo] {
        Dictionary(try lignes("SELECT \(Self.colonnesMemo) FROM memos").compactMap(Self.ligneMemo).map { ($0.fichier, $0) },
                   uniquingKeysWith: { a, _ in a })
    }

    /// Mémos d'un statut, les plus récemment mis à jour d'abord.
    func memos(_ statut: Statut, limite: Int = -1) throws -> [LigneMemo] {
        try lignes("SELECT \(Self.colonnesMemo) FROM memos WHERE statut = ? ORDER BY maj_le DESC, numero DESC LIMIT ?",
                   [.texte(statut.rawValue), .entier(Int64(limite))]).compactMap(Self.ligneMemo)
    }

    /// Mémos dont la note était en cours d'écriture.
    func ecrituresInterrompues() throws -> [LigneMemo] {
        try lignes("SELECT \(Self.colonnesMemo) FROM memos WHERE ecriture_temporaire IS NOT NULL").compactMap(Self.ligneMemo)
    }

    /// Derniers passages, le plus récent d'abord.
    func passages(limite: Int) throws -> [LignePassage] {
        try lignes("SELECT numero, debut, amorces, notes, en_attente, echecs FROM passages ORDER BY numero DESC LIMIT ?",
                   [.entier(Int64(limite))]).map { l in
            LignePassage(numero: l[0].entier ?? 0, debut: l[1].reel ?? 0, amorces: Int(l[2].entier ?? 0),
                         notes: Int(l[3].entier ?? 0), enAttente: Int(l[4].entier ?? 0), echecs: Int(l[5].entier ?? 0))
        }
    }

    // MARK: Écriture

    func fixerDossierAmorce(_ chemin: String) throws {
        try executer("INSERT OR REPLACE INTO reglages (cle, valeur) VALUES ('enregistrements', ?)", [.texte(chemin)])
    }

    @discardableResult
    func inserer(_ f: FichierObserve, statut: Statut, maintenant: Double) throws -> LigneMemo {
        try executer("INSERT INTO memos (fichier, statut, taille, modification, observe_le, maj_le) VALUES (?, ?, ?, ?, ?, ?)",
                     [.texte(f.nom), .texte(statut.rawValue), .entier(f.taille), .reel(f.modification), .reel(maintenant), .reel(maintenant)])
        return LigneMemo(numero: sqlite3_last_insert_rowid(db), fichier: f.nom, statut: statut, taille: f.taille,
                         modification: f.modification, observeLe: maintenant, tentatives: 0, note: nil, majLe: maintenant)
    }

    func enregistrer(_ m: LigneMemo, maintenant: Double) throws {
        try executer("""
            UPDATE memos SET statut = ?, taille = ?, modification = ?, observe_le = ?, tentatives = ?, note = ?, maj_le = ?,
              ecriture_temporaire = ?, ecriture_nom = ?, ecriture_statut = ?
            WHERE numero = ?
            """, [.texte(m.statut.rawValue), .entier(m.taille), .reel(m.modification), .reel(m.observeLe),
                  .entier(Int64(m.tentatives)), m.note.map(Valeur.texte) ?? .nul, .reel(maintenant),
                  m.ecriture.map { .texte($0.temporaire) } ?? .nul, m.ecriture.map { .texte($0.nomDeBase) } ?? .nul,
                  m.ecriture.map { .texte($0.statut.rawValue) } ?? .nul, .entier(m.numero)])
    }

    func supprimer(_ numero: Int64) throws {
        try executer("DELETE FROM memos WHERE numero = ?", [.entier(numero)])
    }

    func noterPassage(debut: Double, fin: Double, _ bilan: BilanPassage) throws {
        try executer("INSERT INTO passages (debut, fin, amorces, notes, en_attente, echecs) VALUES (?, ?, ?, ?, ?, ?)",
                     [.reel(debut), .reel(fin), .entier(Int64(bilan.amorcage ?? 0)), .entier(Int64(bilan.notes.count)),
                      .entier(Int64(bilan.enAttente)), .entier(Int64(bilan.echecs))])
    }

    func transaction(_ corps: () throws -> Void) throws {
        try executer("BEGIN IMMEDIATE")
        do { try corps(); try executer("COMMIT") } catch { try? executer("ROLLBACK"); throw error }
    }

    // MARK: SQLite

    enum Valeur {
        case nul, entier(Int64), reel(Double), texte(String)
        var entier: Int64? { if case let .entier(v) = self { return v }; return nil }
        var reel: Double? {
            switch self { case let .reel(v): return v; case let .entier(v): return Double(v); default: return nil }
        }
        var texte: String? { if case let .texte(v) = self { return v }; return nil }
    }

    private static func ligneMemo(_ l: [Valeur]) -> LigneMemo? {
        guard let numero = l[0].entier, let fichier = l[1].texte, let statut = l[2].texte.flatMap(Statut.init) else { return nil }
        var ecriture: LigneMemo.Ecriture?
        if let temporaire = l[9].texte, let nom = l[10].texte, let vise = l[11].texte.flatMap(Statut.init) {
            ecriture = .init(temporaire: temporaire, nomDeBase: nom, statut: vise)
        }
        return LigneMemo(numero: numero, fichier: fichier, statut: statut, taille: l[3].entier ?? 0,
                         modification: l[4].reel ?? 0, observeLe: l[5].reel ?? 0,
                         tentatives: Int(l[6].entier ?? 0), note: l[7].texte, majLe: l[8].reel ?? 0, ecriture: ecriture)
    }

    private func erreur() -> ErreurEtat { .base(String(cString: sqlite3_errmsg(db))) }

    private func executer(_ sql: String, _ parametres: [Valeur] = []) throws {
        if parametres.isEmpty {
            guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw erreur() }
            return
        }
        let stmt = try preparer(sql, parametres)
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw erreur() }
    }

    private func lignes(_ sql: String, _ parametres: [Valeur] = []) throws -> [[Valeur]] {
        let stmt = try preparer(sql, parametres)
        defer { sqlite3_finalize(stmt) }
        var resultat: [[Valeur]] = []
        while true {
            switch sqlite3_step(stmt) {
            case SQLITE_ROW:
                resultat.append((0..<sqlite3_column_count(stmt)).map { i in
                    switch sqlite3_column_type(stmt, i) {
                    case SQLITE_INTEGER: return .entier(sqlite3_column_int64(stmt, i))
                    case SQLITE_FLOAT: return .reel(sqlite3_column_double(stmt, i))
                    case SQLITE_TEXT: return .texte(String(cString: sqlite3_column_text(stmt, i)))
                    default: return .nul
                    }
                })
            case SQLITE_DONE: return resultat
            default: throw erreur()
            }
        }
    }

    private func preparer(_ sql: String, _ parametres: [Valeur]) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw erreur() }
        let transitoire = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, p) in parametres.enumerated() {
            let rang = Int32(i + 1)
            switch p {
            case .nul: sqlite3_bind_null(stmt, rang)
            case let .entier(v): sqlite3_bind_int64(stmt, rang, v)
            case let .reel(v): sqlite3_bind_double(stmt, rang, v)
            case let .texte(v): sqlite3_bind_text(stmt, rang, v, -1, transitoire)
            }
        }
        return stmt
    }
}
