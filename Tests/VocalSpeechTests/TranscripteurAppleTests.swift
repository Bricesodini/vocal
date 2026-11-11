import Foundation
import Testing
import VocalSpeech

private let fixtures = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures")

/// Test d'intégration du vrai moteur Apple. Sauté, avec un message, si le modèle `fr_FR`
/// n'est pas installé pour le processus de test. macOS lie la réservation du modèle au programme
/// qui la demande : avec `VOCAL_TEST_INSTALLER_MODELE=1`, le test la demande lui-même d'abord.
@Suite("Transcripteur Apple (intégration)",
       .enabled("modèle Apple fr_FR non installé pour ce processus (VOCAL_TEST_INSTALLER_MODELE=1 pour le réserver) : test sauté") {
           let modele = ModeleApple()
           if ProcessInfo.processInfo.environment["VOCAL_TEST_INSTALLER_MODELE"] == "1" {
               try? await modele.installer()
           }
           return (try? await modele.etat()) == .installe
       })
struct TranscripteurAppleTests {
    @Test("transcrit un mémo Watch en .m4a et un mémo iPhone en .qta", arguments: ["watch.m4a", "iphone.qta"])
    func transcrit(_ fichier: String) async throws {
        let texte = try await TranscripteurApple().transcrire(fixtures.appendingPathComponent(fichier))
        let minuscule = texte.lowercased()
        #expect(minuscule.contains("bonjour"))
        #expect(minuscule.contains("mémo de test"))
    }
}
