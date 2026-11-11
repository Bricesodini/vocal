import Foundation

/// Commande `état` : ce que dit la base d'état, lue sans la modifier.
public enum RapportEtat {
    /// Rapport de l'état rangé dans le dossier donné : mémos traités, en attente, en échec, et derniers passages.
    public static func texte(_ dossier: URL, fuseau: TimeZone = .current) throws -> String {
        guard let base = try BaseEtat(lecture: dossier), try base.nombreDePassages() > 0 else {
            return "aucun passage : l'état est vide\n"
        }
        let format = DateFormatter()
        format.locale = Locale(identifier: "fr_FR")
        format.timeZone = fuseau
        format.dateFormat = "yyyy-MM-dd HH:mm"
        func date(_ t: Double) -> String { format.string(from: Date(timeIntervalSince1970: t)) }
        func avecNote(_ m: LigneMemo) -> String { "  n°\(m.numero), le \(date(m.majLe)) : \(m.note ?? "note écrite, nom inconnu")" }

        var lignes = ["ignorés à l'amorçage : \(try base.compter(.ignore))", "traités : \(try base.compter(.traite))"]
        lignes += try base.memos(.traite, limite: 10).map(avecNote)
        let enAttente = try base.memos(.vu).sorted { $0.numero < $1.numero }
        lignes.append("en attente : \(enAttente.count)")
        lignes += enAttente.map { m in
            "  n°\(m.numero), \(m.fichier), vu le \(date(m.observeLe))"
                + (m.tentatives > 0 ? ", \(m.tentatives) tentative(s) échouée(s)" : ", en observation")
        }
        lignes.append("sans parole, écartés : \(try base.compter(.sansParole))")
        lignes.append("en échec : \(try base.compter(.echec))")
        lignes += try base.memos(.echec).map(avecNote)
        lignes.append("derniers passages (\(try base.nombreDePassages()) en tout) :")
        lignes += try base.passages(limite: 5).map { p in
            // Le premier passage est toujours l'amorçage.
            "  \(date(p.debut)) : " + (p.numero == 1
                ? "amorçage, \(p.amorces) mémo(s) ignoré(s)"
                : "\(p.notes) note(s), \(p.enAttente) en attente, \(p.echecs) échec(s)")
        }
        return lignes.joined(separator: "\n") + "\n"
    }
}
