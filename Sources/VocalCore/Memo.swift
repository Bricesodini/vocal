import AVFoundation
import Foundation

/// Appareil sur lequel le mémo a été enregistré, déduit de l'encodeur du Dictaphone.
public enum Appareil: String, Sendable {
    case watch, iphone, ipad

    init?(encodeur: String) {
        guard encodeur.hasPrefix("com.apple.VoiceMemos") else { return nil }
        if encodeur.contains("(Watch ") { self = .watch }
        else if encodeur.contains("(iPhone ") { self = .iphone }
        else if encodeur.contains("(iPad ") { self = .ipad }
        else { return nil }
    }
}

/// Ce que Vocal sait d'un mémo à partir de son fichier audio.
public struct Memo: Sendable {
    public let nom: String
    public let dateEnregistrement: Date
    public let duree: TimeInterval
    public let appareil: Appareil?
    /// Titre inscrit dans le fichier par le Dictaphone, s'il existe.
    public let titreInscrit: String?
    /// Identifiant du mémo inscrit dans le fichier (`voice-memo-uuid`), s'il existe.
    public let identifiant: String?

    static let cleIdentifiant = AVMetadataIdentifier(rawValue: "itlk/com.apple.iTunes.voice-memo-uuid")

    /// Lit les métadonnées du fichier. Le nom vient du titre inscrit dans le fichier, sinon du nom
    /// du fichier. La date vient de la date de création, sinon du nom de fichier du Dictaphone
    /// (`AAAAMMJJ HHMMSS-…`, en heure locale du fuseau donné), sinon de la date de modification.
    /// Échoue si le fichier n'a pas de durée valide.
    public static func lire(_ audio: URL, fuseau: TimeZone) async throws -> Memo {
        let asset = AVURLAsset(url: audio)
        let duree = CMTimeGetSeconds(try await asset.load(.duration))
        guard duree.isFinite, duree > 0 else { throw CocoaError(.fileReadCorruptFile) }
        var titre: String?
        var encodeur: String?
        var identifiant: String?
        for format in try await asset.load(.availableMetadataFormats) {
            for item in try await asset.loadMetadata(for: format) {
                switch item.identifier {
                case .iTunesMetadataSongName, .quickTimeUserDataFullName, .quickTimeMetadataTitle:
                    if titre == nil { titre = try await item.load(.stringValue) }
                case .iTunesMetadataEncodingTool, .quickTimeUserDataSoftware, .quickTimeMetadataSoftware:
                    if encodeur == nil { encodeur = try await item.load(.stringValue) }
                case cleIdentifiant:
                    if identifiant == nil { identifiant = try await item.load(.stringValue) }
                default:
                    break
                }
            }
        }
        var date: Date?
        if let creation = try await asset.load(.creationDate) {
            date = try await creation.load(.dateValue)
        }
        let nomDeFichier = audio.deletingPathExtension().lastPathComponent
        if date == nil { date = dateDuNomDictaphone(nomDeFichier, fuseau: fuseau) }
        if date == nil {
            date = try audio.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        }
        guard let date else { throw CocoaError(.fileReadUnknown) }
        let titreInscrit = titre.flatMap { $0.isEmpty ? nil : $0 }
        // Les mémos récents de l'iPhone arrivent en .qta (audio spatial) sans aucune métadonnée ; la Watch produit
        // des .m4a avec leur encodeur. Un .qta dont l'encodeur ne dit pas l'appareil vient donc de l'iPhone.
        let appareil = encodeur.flatMap(Appareil.init(encodeur:))
            ?? (audio.pathExtension.lowercased() == "qta" ? .iphone : nil)
        return Memo(nom: titreInscrit ?? nomDeFichier, dateEnregistrement: date, duree: duree,
                    appareil: appareil,
                    titreInscrit: titreInscrit, identifiant: identifiant)
    }

    /// Le même mémo, sous le titre que lui donne la base du Dictaphone quand elle en a un : la base fait foi.
    func nomme(_ titre: String?) -> Memo {
        guard let titre else { return self }
        return Memo(nom: titre, dateEnregistrement: dateEnregistrement, duree: duree, appareil: appareil,
                    titreInscrit: titreInscrit, identifiant: identifiant)
    }

    /// Ce qu'on sait d'un fichier illisible, pour signaler son échec : nom et date viennent du nom
    /// de fichier du Dictaphone, sinon de la date de modification ; la durée est inconnue (0).
    static func deSecours(_ audio: URL, fuseau: TimeZone, repli: Date) -> Memo {
        let nom = audio.deletingPathExtension().lastPathComponent
        let date = dateDuNomDictaphone(nom, fuseau: fuseau)
            ?? (try? audio.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            ?? repli
        return Memo(nom: nom, dateEnregistrement: date, duree: 0, appareil: nil, titreInscrit: nil, identifiant: nil)
    }

    /// Date d'un nom de fichier du Dictaphone, par exemple `20261009 132121-7EB013BF`.
    static func dateDuNomDictaphone(_ nom: String, fuseau: TimeZone) -> Date? {
        guard let m = nom.wholeMatch(of: /(\d{4})(\d{2})(\d{2}) (\d{2})(\d{2})(\d{2})-.+/) else { return nil }
        var calendrier = Calendar(identifier: .gregorian)
        calendrier.timeZone = fuseau
        let composantes = DateComponents(year: Int(m.1), month: Int(m.2), day: Int(m.3),
                                         hour: Int(m.4), minute: Int(m.5), second: Int(m.6))
        guard composantes.isValidDate(in: calendrier) else { return nil }
        return calendrier.date(from: composantes)
    }
}
