import Foundation
import Synchronization
import VocalCore

/// Dossier des fichiers audio de synthèse, fabriqués par scripts/make-fixtures.sh.
let fixtures = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures")

/// Transcripteur factice : rend un texte fixé, ou échoue.
struct TranscripteurFactice: Transcripteur {
    var texte: String
    func transcrire(_ audio: URL) async throws -> String { texte }
}

/// Transcripteur qui ne doit jamais être appelé : il fait échouer le test s'il l'est.
struct TranscripteurQuiEchoue: Transcripteur {
    struct AppelInattendu: Error {}
    func transcrire(_ audio: URL) async throws -> String { throw AppelInattendu() }
}

/// Transcripteur toujours en panne, qui compte ses appels.
final class TranscripteurEnPanne: Transcripteur, Sendable {
    struct Panne: Error {}
    private let compte = Mutex(0)
    var appels: Int { compte.withLock { $0 } }
    func transcrire(_ audio: URL) async throws -> String {
        compte.withLock { $0 += 1 }
        throw Panne()
    }
}

/// Transcripteur dont le modèle n'est pas prêt : la préparation échoue.
struct TranscripteurPasPret: Transcripteur {
    struct ModeleAbsent: Error {}
    func preparer() async throws { throw ModeleAbsent() }
    func transcrire(_ audio: URL) async throws -> String { "ne doit pas servir" }
}

/// Crée un dossier temporaire vide, propre à un test.
func dossierTemporaire() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("vocal-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func contenu(_ dossier: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: dossier.path).sorted()
}

let paris = TimeZone(identifier: "Europe/Paris")!
