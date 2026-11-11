import AVFoundation
import Foundation
import Speech
import VocalCore

/// Transcription sur le Mac avec Apple SpeechTranscriber. Lit le fichier avec AVAudioFile :
/// pour un `.qta` en audio spatial, c'est la piste stéréo AAC, seule activée, qui est lue.
public struct TranscripteurApple: Transcripteur {
    let modele: ModeleApple

    public init(modele: ModeleApple = ModeleApple()) { self.modele = modele }

    /// Vérifie le modèle et, s'il manque, le réserve et l'installe : macOS peut retirer un modèle inutilisé.
    public func preparer() async throws {
        guard try await modele.etat() != .installe else { return }
        try await modele.installer()
        let etat = try await modele.etat()
        guard etat == .installe else { throw ModeleApple.Erreur.modeleAbsent(etat) }
    }

    public func transcrire(_ audio: URL) async throws -> String {
        let etat = try await modele.etat()
        guard etat == .installe else { throw ModeleApple.Erreur.modeleAbsent(etat) }

        let fichier = try AVAudioFile(forReading: audio)
        let module = try await modele.module()
        let analyseur = SpeechAnalyzer(modules: [module])
        let collecte = Task {
            var texte = ""
            for try await resultat in module.results { texte += String(resultat.text.characters) }
            return texte
        }
        do {
            if let dernier = try await analyseur.analyzeSequence(from: fichier) {
                try await analyseur.finalizeAndFinish(through: dernier)
            } else {
                await analyseur.cancelAndFinishNow()
            }
        } catch {
            collecte.cancel()
            await analyseur.cancelAndFinishNow()
            throw error
        }
        return try await collecte.value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
