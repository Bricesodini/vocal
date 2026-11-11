import Foundation
import VocalCore

/// Échec d'un appel au LLM. Aucune de ces erreurs ne reprend de clé, de texte du mémo ou de contenu de réponse.
public enum ErreurRedacteur: ErreurSansContenu, Equatable {
    case cleIntrouvable(String)
    case trousseau(Int32)
    case trousseauSansReponse
    case statutHTTP(Int)
    case delaiDepasse
    case reseau(Int)
    case reponseIncomplete(String)
    case reponseMalFormee(String)

    public var description: String {
        switch self {
        case let .cleIntrouvable(nom): return "clé introuvable dans le trousseau : « \(nom) »"
        case let .trousseau(statut): return "lecture du trousseau refusée (OSStatus \(statut))"
        case let .statutHTTP(code): return "le fournisseur a répondu HTTP \(code)"
        case .trousseauSansReponse:
            return "le trousseau n'a pas répondu à temps : une demande d'autorisation attend peut-être, l'entrée doit autoriser Vocal.app"
        case .delaiDepasse: return "délai de réponse dépassé"
        case let .reseau(code): return "erreur réseau (\(code))"
        case let .reponseIncomplete(raison): return "réponse incomplète (\(raison))"
        case let .reponseMalFormee(raison): return "réponse mal formée : \(raison)"
        }
    }
}
