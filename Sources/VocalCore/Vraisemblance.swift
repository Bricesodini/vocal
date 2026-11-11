import Foundation

public enum ErreurTranscription: Error, Equatable, CustomStringConvertible {
    /// Transcription vide, ou de moins de 10 mots par minute au-delà de 20 s d'audio.
    case invraisemblable(mots: Int, duree: Int)

    public var description: String {
        switch self {
        case let .invraisemblable(mots, duree):
            return "transcription invraisemblable : \(mots) mot(s) pour \(duree) s d'audio"
        }
    }
}

enum Vraisemblance {
    static let dureeMinimaleControlee: TimeInterval = 20
    static let motsParMinuteMinimum = 10.0

    static func verifier(_ texte: String, duree: TimeInterval) throws {
        let mots = texte.split(whereSeparator: \.isWhitespace).count
        let tropPeu = duree > dureeMinimaleControlee && Double(mots) / (duree / 60) < motsParMinuteMinimum
        if mots == 0 || tropPeu {
            throw ErreurTranscription.invraisemblable(mots: mots, duree: Int(duree.rounded()))
        }
    }
}
