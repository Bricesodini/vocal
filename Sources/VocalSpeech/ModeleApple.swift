import Foundation
import Speech

/// Modèle de transcription Apple pour une langue. Son état est géré par macOS et partagé entre
/// apps ; la réservation est liée à l'app qui la demande.
public struct ModeleApple: Sendable {
    public enum Etat: String, Sendable {
        case installe = "installé"
        case aTelecharger = "à télécharger"
        case telechargement = "téléchargement en cours"
        case nonPrisEnCharge = "langue non prise en charge"
    }

    public enum Erreur: Error, CustomStringConvertible {
        case indisponible
        case langueNonPriseEnCharge(String)
        case modeleAbsent(Etat)

        public var description: String {
            switch self {
            case .indisponible: return "SpeechTranscriber n'est pas disponible sur ce Mac"
            case let .langueNonPriseEnCharge(l): return "langue non prise en charge : \(l)"
            case let .modeleAbsent(e): return "modèle de transcription non installé (\(e.rawValue)) : lancer « Vocal modèle --installer »"
            }
        }
    }

    public let langue: String

    public init(langue: String = "fr_FR") { self.langue = langue }

    /// Module SpeechTranscriber configuré comme le Dictaphone : texte final, sans options.
    func module() async throws -> SpeechTranscriber {
        guard SpeechTranscriber.isAvailable else { throw Erreur.indisponible }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: langue)) else {
            throw Erreur.langueNonPriseEnCharge(langue)
        }
        return SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
    }

    public func etat() async throws -> Etat {
        switch await AssetInventory.status(forModules: [try await module()]) {
        case .installed: return .installe
        case .supported: return .aTelecharger
        case .downloading: return .telechargement
        case .unsupported: return .nonPrisEnCharge
        @unknown default: return .nonPrisEnCharge
        }
    }

    /// Réserve la langue pour cette app, puis télécharge et installe le modèle si besoin.
    public func installer() async throws {
        if let requete = try await AssetInventory.assetInstallationRequest(supporting: [try await module()]) {
            try await requete.downloadAndInstall()
        }
    }

    /// État de l'autorisation « Reconnaissance vocale » pour ce processus, sans la demander.
    public static func autorisationReconnaissance() -> String {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return "accordée"
        case .denied: return "refusée"
        case .restricted: return "restreinte"
        case .notDetermined: return "jamais demandée"
        @unknown default: return "inconnue"
        }
    }
}
