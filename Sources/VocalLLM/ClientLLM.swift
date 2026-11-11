import Foundation
import Synchronization
import VocalCore

/// Rédacteur qui appelle un LLM par le protocole `openai-compatible` ou `anthropic`.
public struct ClientLLM: Redacteur {
    static let versionAnthropic = "2026-10-21"
    static let jetonsMax = 16000

    let reglage: Reglages.LLM
    let glossaire: [String]
    let trousseau: LectureTrousseau
    let delaiTrousseau: TimeInterval
    let session: URLSession

    public var nom: String { reglage.nom }

    /// `delaiTrousseau` borne la lecture de la clé : sous launchd, une demande d'autorisation de macOS
    /// resterait sans réponse et bloquerait le passage.
    public init(_ reglage: Reglages.LLM, glossaire: [String], trousseau: @escaping LectureTrousseau = Trousseau.lire,
                delaiTrousseau: TimeInterval = 10) {
        self.reglage = reglage
        self.glossaire = glossaire
        self.trousseau = trousseau
        self.delaiTrousseau = delaiTrousseau
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = reglage.delai
        configuration.timeoutIntervalForResource = reglage.delai
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
    }

    public func rediger(_ transcription: String) async throws -> Redaction {
        var cle: String?
        if let entree = reglage.cleTrousseau { cle = try await Self.lire(entree, trousseau, delai: delaiTrousseau) }
        let message = Consigne.message(transcription: transcription, glossaire: glossaire)
        var requete: URLRequest
        let corps: [String: Any]
        switch reglage.protocole {
        case .openaiCompatible:
            requete = URLRequest(url: reglage.adresse.appendingPathComponent("chat/completions"))
            if let cle { requete.setValue("Bearer \(cle)", forHTTPHeaderField: "Authorization") }
            corps = ["model": reglage.modele, "stream": false,
                     "messages": [["role": "system", "content": Consigne.systeme], ["role": "user", "content": message]]]
        case .anthropic:
            requete = URLRequest(url: reglage.adresse.appendingPathComponent("messages"))
            if let cle { requete.setValue(cle, forHTTPHeaderField: "x-api-key") }
            requete.setValue(Self.versionAnthropic, forHTTPHeaderField: "anthropic-version")
            corps = ["model": reglage.modele, "max_tokens": Self.jetonsMax, "system": Consigne.systeme,
                     "messages": [["role": "user", "content": message]]]
        }
        requete.httpMethod = "POST"
        requete.setValue("application/json", forHTTPHeaderField: "Content-Type")
        requete.httpBody = try JSONSerialization.data(withJSONObject: corps)

        let donnees: Data, reponse: URLResponse
        do {
            (donnees, reponse) = try await session.data(for: requete)
        } catch let erreur as URLError {
            throw erreur.code == .timedOut ? ErreurRedacteur.delaiDepasse : ErreurRedacteur.reseau(erreur.code.rawValue)
        }
        let statut = (reponse as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(statut) else { throw ErreurRedacteur.statutHTTP(statut) }
        return try Consigne.lire(try texteRendu(donnees))
    }

    /// Lit une entrée du trousseau sans attendre plus que `delai`. Passé ce délai, la lecture est abandonnée :
    /// elle se termine en arrière-plan, et le processus du passage s'arrête peu après.
    static func lire(_ entree: String, _ trousseau: @escaping LectureTrousseau, delai: TimeInterval) async throws -> String {
        try await withCheckedThrowingContinuation { suite in
            let rendue = Mutex(false)
            let rendre: @Sendable (Result<String, any Error>) -> Void = { resultat in
                if rendue.withLock({ deja in defer { deja = true }; return !deja }) { suite.resume(with: resultat) }
            }
            DispatchQueue.global().async { rendre(Result { try trousseau(entree) }) }
            DispatchQueue.global().asyncAfter(deadline: .now() + delai) { rendre(.failure(ErreurRedacteur.trousseauSansReponse)) }
        }
    }

    /// Raison de fin anormale, prise dans une liste fermée : rien de la réponse n'est recopié.
    static func raisonDeFin(_ valeur: String) -> String {
        ["length", "max_tokens", "refusal", "content_filter"].contains(valeur) ? valeur : "autre"
    }

    /// Le texte rendu par le modèle, ou une erreur si la réponse est tronquée, refusée ou illisible.
    private func texteRendu(_ donnees: Data) throws -> String {
        guard let objet = try? JSONSerialization.jsonObject(with: donnees) as? [String: Any] else {
            throw ErreurRedacteur.reponseMalFormee("corps non JSON")
        }
        switch reglage.protocole {
        case .openaiCompatible:
            guard let choix = (objet["choices"] as? [[String: Any]])?.first,
                  let contenu = (choix["message"] as? [String: Any])?["content"] as? String else {
                throw ErreurRedacteur.reponseMalFormee("aucun message")
            }
            if let fin = choix["finish_reason"] as? String, fin != "stop" { throw ErreurRedacteur.reponseIncomplete(Self.raisonDeFin(fin)) }
            return contenu
        case .anthropic:
            if let arret = objet["stop_reason"] as? String, arret != "end_turn" { throw ErreurRedacteur.reponseIncomplete(Self.raisonDeFin(arret)) }
            let blocs = (objet["content"] as? [[String: Any]] ?? []).filter { $0["type"] as? String == "text" }
            guard !blocs.isEmpty else { throw ErreurRedacteur.reponseMalFormee("aucun bloc de texte") }
            return blocs.compactMap { $0["text"] as? String }.joined()
        }
    }
}
