import Foundation
import Network
import Synchronization

/// Petit serveur HTTP sur 127.0.0.1 qui imite un fournisseur de LLM : il garde les requêtes reçues
/// et rend une réponse fixée, éventuellement après un délai.
final class ServeurLocal: Sendable {
    struct Requete: Sendable {
        let ligne: String
        let entetes: [String: String]
        let corps: Data
        var json: [String: Any] { (try? JSONSerialization.jsonObject(with: corps)) as? [String: Any] ?? [:] }
    }
    struct Reponse: Sendable {
        var statut = 200
        var corps = "{}"
        var delai: TimeInterval = 0
    }

    private let listener: NWListener
    private let file = DispatchQueue(label: "serveur-local")
    private let etat = Mutex<(reponse: Reponse, requetes: [Requete])>((Reponse(), []))
    let adresse: URL

    var requetes: [Requete] { etat.withLock { $0.requetes } }
    func repondre(_ reponse: Reponse) { etat.withLock { $0.reponse = reponse } }

    init() async throws {
        let parametres = NWParameters.tcp
        parametres.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let ecoute = try NWListener(using: parametres)
        listener = ecoute
        let file = self.file
        let pret: NWEndpoint.Port = try await withCheckedThrowingContinuation { suite in
            let une = Mutex(false)
            ecoute.stateUpdateHandler = { e in
                switch e {
                case .ready: if !une.withLock({ let v = $0; $0 = true; return v }) { suite.resume(returning: ecoute.port!) }
                case let .failed(err): if !une.withLock({ let v = $0; $0 = true; return v }) { suite.resume(throwing: err) }
                default: break
                }
            }
            ecoute.newConnectionHandler = { _ in }
            ecoute.start(queue: file)
        }
        adresse = URL(string: "http://127.0.0.1:\(pret.rawValue)/v1")!
        listener.newConnectionHandler = { [weak self] connexion in
            connexion.start(queue: file)
            self?.lire(connexion, Data())
        }
    }

    func arreter() { listener.cancel() }

    private func lire(_ connexion: NWConnection, _ recu: Data) {
        connexion.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] donnees, _, fin, erreur in
            guard let self else { return }
            var tout = recu
            if let donnees { tout.append(donnees) }
            if let requete = Self.analyser(tout) {
                self.servir(connexion, requete)
            } else if fin || erreur != nil {
                connexion.cancel()
            } else {
                self.lire(connexion, tout)
            }
        }
    }

    private func servir(_ connexion: NWConnection, _ requete: Requete) {
        let reponse = etat.withLock { $0.requetes.append(requete); return $0.reponse }
        file.asyncAfter(deadline: .now() + reponse.delai) {
            let corps = Data(reponse.corps.utf8)
            let tete = "HTTP/1.1 \(reponse.statut) X\r\nContent-Type: application/json\r\nContent-Length: \(corps.count)\r\nConnection: close\r\n\r\n"
            connexion.send(content: Data(tete.utf8) + corps, completion: .contentProcessed { _ in connexion.cancel() })
        }
    }

    /// Une requête complète (en-têtes et corps selon Content-Length), ou rien s'il manque des octets.
    private static func analyser(_ donnees: Data) -> Requete? {
        guard let fin = donnees.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let lignes = String(decoding: donnees[..<fin.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        var entetes: [String: String] = [:]
        for l in lignes.dropFirst() {
            guard let deuxPoints = l.firstIndex(of: ":") else { continue }
            entetes[l[..<deuxPoints].lowercased()] = l[l.index(after: deuxPoints)...].trimmingCharacters(in: .whitespaces)
        }
        let longueur = Int(entetes["content-length"] ?? "0") ?? 0
        let corps = donnees[fin.upperBound...]
        guard corps.count >= longueur else { return nil }
        return Requete(ligne: lignes.first ?? "", entetes: entetes, corps: Data(corps.prefix(longueur)))
    }
}
