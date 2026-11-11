import Foundation

/// Ce qui transforme un fichier audio en transcription brute.
public protocol Transcripteur: Sendable {
    /// Rend le transcripteur prêt, par exemple en installant son modèle. Un échec ici n'est la faute
    /// d'aucun mémo : le passage s'arrête sans compter de tentative.
    func preparer() async throws
    func transcrire(_ audio: URL) async throws -> String
}

extension Transcripteur {
    public func preparer() async throws {}
}
