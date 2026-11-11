import Foundation

/// Note vocale écrite dans l'inbox. Le frontmatter vient de Vocal et du fichier audio, jamais d'un LLM.
public struct NoteVocale: Sendable {
    public static let titreDeRepli = "Vocal sans titre"
    public static let titreTranscriptionImpossible = "Vocal transcription impossible"

    let memo: Memo
    let transcriptionBrute: String
    /// Rédaction contrôlée par Vocal, ou rien si le rédacteur n'a pas donné de réponse valide.
    let redaction: Redaction?
    /// `fournisseur/modèle` du rédacteur. Il n'est inscrit qu'avec une rédaction : sinon le champ vaut `aucun`.
    let llm: String?
    /// La note signale un mémo dont la transcription a échoué trois fois : elle n'a pas de texte.
    let transcriptionImpossible: Bool

    init(memo: Memo, transcriptionBrute: String, redaction: Redaction? = nil, llm: String? = nil) {
        self.memo = memo
        self.transcriptionBrute = transcriptionBrute
        self.redaction = redaction
        self.llm = redaction == nil ? nil : llm
        transcriptionImpossible = false
    }

    /// Note qui signale l'échec définitif de la transcription d'un mémo.
    init(transcriptionImpossible memo: Memo) {
        self.memo = memo
        transcriptionBrute = ""
        redaction = nil
        llm = nil
        transcriptionImpossible = true
    }

    var titre: String {
        transcriptionImpossible ? Self.titreTranscriptionImpossible : redaction?.titre ?? Self.titreDeRepli
    }

    /// Nom de fichier sans suffixe de collision : `AAAA-MM-JJ HHhMM - Vocal - <titre>`.
    func nomDeBase(fuseau: TimeZone) -> String {
        "\(jour(fuseau)) \(heure(fuseau)) - Vocal - \(titre)"
    }

    func texte(fuseau: TimeZone) -> String {
        var lignes = [
            "---",
            "type: note-vocale",
            "date: \(jour(fuseau))",
            "source: vocal",
            "statut: à traiter",
            "duree: \(yaml(Self.duree(memo.duree)))",
            "memo: \(yaml(memo.nom))",
        ]
        if let appareil = memo.appareil { lignes.append("appareil: \(appareil.rawValue)") }
        lignes += [
            "llm: \(llm.map(yaml) ?? "aucun")",
            "---",
            "",
            "# \(titre)",
            "",
        ]
        if transcriptionImpossible {
            lignes += ["La transcription de ce mémo a échoué trois fois. L'audio reste intact dans le Dictaphone.", ""]
            return lignes.joined(separator: "\n")
        }
        if let redaction {
            lignes += ["## Résumé", "", redaction.resume, "", "## Texte nettoyé", "", redaction.texte, ""]
        }
        lignes += [
            "## Transcription brute",
            "",
            transcriptionBrute.trimmingCharacters(in: .whitespacesAndNewlines),
            "",
        ]
        return lignes.joined(separator: "\n")
    }

    /// Durée arrondie à la seconde, en `M:SS` (les minutes ne sont pas plafonnées).
    static func duree(_ secondes: TimeInterval) -> String {
        let total = Int(secondes.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// `AAAA-MM-JJ` de l'enregistrement dans le fuseau donné.
    private func jour(_ fuseau: TimeZone) -> String {
        let d = composantes(fuseau)
        return String(format: "%04d-%02d-%02d", d.year!, d.month!, d.day!)
    }

    /// `HHhMM` de l'enregistrement dans le fuseau donné.
    private func heure(_ fuseau: TimeZone) -> String {
        let d = composantes(fuseau)
        return String(format: "%02dh%02d", d.hour!, d.minute!)
    }

    private func composantes(_ fuseau: TimeZone) -> DateComponents {
        var calendrier = Calendar(identifier: .gregorian)
        calendrier.timeZone = fuseau
        return calendrier.dateComponents([.year, .month, .day, .hour, .minute], from: memo.dateEnregistrement)
    }

    /// Chaîne YAML entre guillemets doubles.
    private func yaml(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
