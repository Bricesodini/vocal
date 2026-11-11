import Foundation

public enum ErreurReglages: Error, Equatable, CustomStringConvertible {
    case illisible(String)
    case cleEnClair(fournisseur: String)
    case fournisseurInconnu(String)
    case modeleMalForme
    case protocoleInconnu(fournisseur: String)
    case adresseManquante(fournisseur: String)
    case champInconnu(fournisseur: String, champ: String)

    public var description: String {
        switch self {
        case let .illisible(raison): return "fichier de réglages illisible : \(raison)"
        case let .cleEnClair(f): return "fournisseur « \(f) » : la clé doit être une référence au trousseau (keychain:<nom>), jamais une clé en clair"
        case let .fournisseurInconnu(f): return "le modèle désigne un fournisseur inconnu : « \(f) »"
        case .modeleMalForme: return "le modèle doit avoir la forme fournisseur/modèle"
        case let .protocoleInconnu(f): return "fournisseur « \(f) » : protocole inconnu (openai-compatible ou anthropic)"
        case let .adresseManquante(f): return "fournisseur « \(f) » : baseURL manquante"
        case let .champInconnu(f, c): return "fournisseur « \(f) » : champ inconnu « \(c) » (protocol, baseURL, apiKey, timeoutSeconds)"
        }
    }
}

/// Réglages de Vocal, lus dans un fichier JSON au format inspiré d'opencode.
public struct Reglages: Sendable, Equatable {
    public enum Protocole: String, Sendable { case openaiCompatible = "openai-compatible", anthropic }

    /// Le LLM choisi par `model`, avec les réglages de son fournisseur.
    public struct LLM: Sendable, Equatable {
        /// `fournisseur/modèle`, tel qu'écrit dans les réglages et inscrit dans le champ `llm` de la note.
        public let nom: String
        /// Le modèle tel que le fournisseur le connaît.
        public let modele: String
        public let protocole: Protocole
        public let adresse: URL
        /// Nom de l'entrée du trousseau qui contient la clé, ou rien pour un fournisseur local sans clé.
        public let cleTrousseau: String?
        /// Délai maximal de la réponse, en secondes.
        public let delai: TimeInterval

        public init(nom: String, modele: String, protocole: Protocole, adresse: URL, cleTrousseau: String?, delai: TimeInterval) {
            self.nom = nom
            self.modele = modele
            self.protocole = protocole
            self.adresse = adresse
            self.cleTrousseau = cleTrousseau
            self.delai = delai
        }
    }

    public static let delaiParDefaut: TimeInterval = 120
    static let prefixeTrousseau = "keychain:"
    static let adresseAnthropic = URL(string: "https://api.anthropic.com/v1")!

    public var inbox: URL?
    public var locale = "fr_FR"
    /// Aucun LLM tant que `model` n'est pas réglé : c'est le défaut, pour la confidentialité.
    public var llm: LLM?
    public var glossaire: [String] = []

    public init() {}

    /// Lit les réglages. Un fichier absent donne les réglages par défaut ; un fichier invalide est refusé.
    public static func charger(_ fichier: URL) throws -> Reglages {
        guard FileManager.default.fileExists(atPath: fichier.path) else { return Reglages() }
        let brut: Fichier
        do {
            brut = try JSONDecoder().decode(Fichier.self, from: try Data(contentsOf: fichier))
        } catch let erreur as DecodingError {
            throw ErreurReglages.illisible(Self.raison(erreur))
        } catch {
            throw ErreurReglages.illisible("lecture impossible")
        }

        struct Fournisseur { let protocole: Protocole; let adresse: URL; let cle: String?; let delai: TimeInterval }
        var fournisseurs: [String: Fournisseur] = [:]
        for (nom, f) in brut.providers ?? [:] {
            // Un champ inconnu peut cacher une clé en clair (`options.apiKey` dans opencode) : il fait refuser le fichier.
            if let champ = f.champsInconnus.sorted().first { throw ErreurReglages.champInconnu(fournisseur: nom, champ: champ) }
            var cle: String?
            if let apiKey = f.apiKey {
                guard apiKey.hasPrefix(prefixeTrousseau), apiKey.count > prefixeTrousseau.count else {
                    throw ErreurReglages.cleEnClair(fournisseur: nom)
                }
                cle = String(apiKey.dropFirst(prefixeTrousseau.count))
            }
            guard let protocole = Protocole(rawValue: f.protocol ?? "") else {
                throw ErreurReglages.protocoleInconnu(fournisseur: nom)
            }
            let adresse: URL
            if let texte = f.baseURL, let url = URL(string: texte), url.scheme != nil {
                adresse = url
            } else if f.baseURL == nil, protocole == .anthropic {
                adresse = adresseAnthropic
            } else {
                throw ErreurReglages.adresseManquante(fournisseur: nom)
            }
            fournisseurs[nom] = Fournisseur(protocole: protocole, adresse: adresse, cle: cle, delai: f.timeoutSeconds ?? delaiParDefaut)
        }

        var reglages = Reglages()
        reglages.inbox = brut.inbox.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
        reglages.locale = brut.locale ?? reglages.locale
        reglages.glossaire = brut.glossary ?? []
        let model = (brut.model ?? "").trimmingCharacters(in: .whitespaces)
        if !model.isEmpty {
            guard let barre = model.firstIndex(of: "/"), barre != model.startIndex, model.index(after: barre) != model.endIndex else {
                throw ErreurReglages.modeleMalForme
            }
            let nomFournisseur = String(model[..<barre])
            guard let f = fournisseurs[nomFournisseur] else { throw ErreurReglages.fournisseurInconnu(nomFournisseur) }
            reglages.llm = LLM(nom: model, modele: String(model[model.index(after: barre)...]), protocole: f.protocole,
                               adresse: f.adresse, cleTrousseau: f.cle, delai: f.delai)
        }
        return reglages
    }

    /// Raison d'un échec de décodage, sans aucune valeur du fichier (une clé pourrait s'y trouver).
    private static func raison(_ erreur: DecodingError) -> String {
        switch erreur {
        case .dataCorrupted: return "JSON invalide"
        case let .typeMismatch(_, c), let .valueNotFound(_, c):
            return "type inattendu pour « \(c.codingPath.map(\.stringValue).joined(separator: ".")) »"
        case let .keyNotFound(cle, _): return "champ manquant « \(cle.stringValue) »"
        @unknown default: return "JSON invalide"
        }
    }

    private struct Fichier: Decodable {
        struct Fournisseur: Decodable {
            var `protocol`: String?
            var baseURL: String?
            var apiKey: String?
            var timeoutSeconds: TimeInterval?
            /// Noms des champs présents mais non reconnus (jamais leurs valeurs).
            var champsInconnus: [String] = []

            private enum Cle: String, CodingKey, CaseIterable { case `protocol`, baseURL, apiKey, timeoutSeconds }
            private struct Quelconque: CodingKey {
                let stringValue: String
                var intValue: Int? { nil }
                init(stringValue: String) { self.stringValue = stringValue }
                init?(intValue: Int) { nil }
            }

            init(from decoder: any Decoder) throws {
                let c = try decoder.container(keyedBy: Cle.self)
                `protocol` = try c.decodeIfPresent(String.self, forKey: .protocol)
                baseURL = try c.decodeIfPresent(String.self, forKey: .baseURL)
                apiKey = try c.decodeIfPresent(String.self, forKey: .apiKey)
                timeoutSeconds = try c.decodeIfPresent(TimeInterval.self, forKey: .timeoutSeconds)
                champsInconnus = try decoder.container(keyedBy: Quelconque.self).allKeys
                    .map(\.stringValue).filter { Cle(rawValue: $0) == nil }
            }
        }
        var inbox: String?
        var locale: String?
        var model: String?
        var providers: [String: Fournisseur]?
        var glossary: [String]?
    }
}
