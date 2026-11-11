import Foundation

/// Ce que le rédacteur rend pour un mémo : un titre, un résumé court et le texte nettoyé.
public struct Redaction: Sendable, Equatable {
    public var titre: String
    public var resume: String
    public var texte: String

    public init(titre: String, resume: String, texte: String) {
        self.titre = titre
        self.resume = resume
        self.texte = texte
    }
}

/// L'appel au LLM qui rédige une note à partir de la transcription brute.
public protocol Redacteur: Sendable {
    /// `fournisseur/modèle`, inscrit dans le champ `llm` de la note.
    var nom: String { get }
    func rediger(_ transcription: String) async throws -> Redaction
}

/// Erreur de rédacteur dont la description ne contient jamais de clé, de texte du mémo ni de contenu de réponse.
/// Seules ces erreurs donnent leur description comme raison de rejet ; les autres ne donnent que leur type.
public protocol ErreurSansContenu: Error, CustomStringConvertible {}

/// Ce qu'il est advenu de la rédaction d'une note. La raison d'un rejet ne contient jamais de texte du mémo.
public enum IssueRedaction: Sendable, Equatable {
    case sansLLM
    case redigee
    case rejetee(String)
}

/// Contrôle d'une rédaction avant de l'écrire dans la note.
enum ControleRedaction {
    static let longueurTitreMax = 80

    /// Rend la rédaction prête à écrire (titre nettoyé), ou la raison de son rejet.
    static func verifier(_ redaction: Redaction, brut: String) -> Result<Redaction, Rejet> {
        let titre = nettoyerTitre(redaction.titre)
        guard !titre.isEmpty else { return .failure(Rejet(raison: "titre vide")) }
        let motsBrut = mots(brut), motsTexte = mots(redaction.texte)
        guard motsTexte * 10 >= motsBrut * 5, motsTexte * 10 <= motsBrut * 12 else {
            return .failure(Rejet(raison: "texte nettoyé à \(motsTexte) mots pour \(motsBrut)"))
        }
        return .success(Redaction(titre: titre,
                                  resume: redaction.resume.trimmingCharacters(in: .whitespacesAndNewlines),
                                  texte: redaction.texte.trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    struct Rejet: Error { let raison: String }

    /// Retire les caractères interdits dans un nom de fichier ou un lien Obsidian, les espaces en trop
    /// et les points de tête, puis coupe à `longueurTitreMax` caractères sur une fin de mot.
    static func nettoyerTitre(_ titre: String) -> String {
        let interdits = CharacterSet(charactersIn: "/\\:*?\"<>|#^[]").union(.controlCharacters).union(.newlines)
        var propre = String(String.UnicodeScalarView(titre.unicodeScalars.map { interdits.contains($0) ? " " : $0 }))
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        while propre.hasPrefix(".") { propre = String(propre.dropFirst()).trimmingCharacters(in: .whitespaces) }
        guard propre.count > longueurTitreMax else { return propre }
        let coupe = propre.prefix(longueurTitreMax)
        let suivant = propre[coupe.endIndex]
        let finDeMot = suivant == " " ? coupe : (coupe.lastIndex(of: " ").map { coupe[..<$0] } ?? coupe)
        return finDeMot.trimmingCharacters(in: .whitespaces)
    }

    static func mots(_ texte: String) -> Int { texte.split(whereSeparator: \.isWhitespace).count }
}
