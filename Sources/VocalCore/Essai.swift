import Foundation

public enum ErreurEssai: Error, Equatable, CustomStringConvertible {
    case destinationAbsente(String)
    case audioIllisible(String)

    public var description: String {
        switch self {
        case let .destinationAbsente(chemin): return "le dossier de destination n'existe pas : \(chemin)"
        case let .audioIllisible(chemin): return "fichier audio illisible : \(chemin)"
        }
    }
}

/// Une note écrite, et ce qu'il est advenu de sa rédaction par le LLM.
public struct NoteEcrite: Sendable, Equatable {
    public let url: URL
    public let redaction: IssueRedaction
}

/// Commande `essai` : transcrit un fichier audio et écrit une note vocale dans un dossier donné.
public struct Essai: Sendable {
    let transcripteur: any Transcripteur
    let redacteur: (any Redacteur)?
    let fuseau: TimeZone

    /// Sans rédacteur, aucun LLM n'est appelé.
    public init(transcripteur: any Transcripteur, redacteur: (any Redacteur)? = nil, fuseau: TimeZone = .current) {
        self.transcripteur = transcripteur
        self.redacteur = redacteur
        self.fuseau = fuseau
    }

    /// Écrit la note. Le dossier de destination doit exister : il n'est jamais créé.
    /// Un rédacteur absent, en échec ou à la réponse invalide n'empêche jamais l'écriture.
    public func executer(audio: URL, destination: URL) async throws -> NoteEcrite {
        var estDossier: ObjCBool = false
        guard FileManager.default.fileExists(atPath: destination.path, isDirectory: &estDossier), estDossier.boolValue else {
            throw ErreurEssai.destinationAbsente(destination.path)
        }
        let memo: Memo
        do { memo = try await Memo.lire(audio, fuseau: fuseau) } catch { throw ErreurEssai.audioIllisible(audio.path) }
        let traitement = Traitement(transcripteur: transcripteur, redacteur: redacteur, fuseau: fuseau)
        let texte = try await traitement.transcrire(audio, memo: memo)
        let redigee = await traitement.note(memo, transcription: texte)
        let url = try EcritureNote.ecrire(redigee.note.texte(fuseau: fuseau), nomDeBase: redigee.note.nomDeBase(fuseau: fuseau),
                                          dans: destination)
        return NoteEcrite(url: url, redaction: redigee.issue)
    }
}

/// Ce que partagent `essai` et `passage` : transcrire un mémo, puis écrire sa note.
struct Traitement: Sendable {
    let transcripteur: any Transcripteur
    let redacteur: (any Redacteur)?
    let fuseau: TimeZone

    /// Transcription brute, contrôlée : une transcription invraisemblable est une erreur.
    func transcrire(_ audio: URL, memo: Memo) async throws -> String {
        let texte = try await transcripteur.transcrire(audio)
        try Vraisemblance.verifier(texte, duree: memo.duree)
        return texte
    }

    /// Note vocale d'un mémo transcrit, rédigée si un rédacteur est réglé, avec l'issue et la durée de la rédaction.
    func note(_ memo: Memo, transcription texte: String) async -> (note: NoteVocale, issue: IssueRedaction, duree: Duration) {
        let debut = ContinuousClock.now
        let (redaction, issue) = await rediger(texte)
        return (NoteVocale(memo: memo, transcriptionBrute: texte, redaction: redaction, llm: redacteur?.nom), issue,
                ContinuousClock.now - debut)
    }

    private func rediger(_ brut: String) async -> (Redaction?, IssueRedaction) {
        guard let redacteur else { return (nil, .sansLLM) }
        do {
            switch ControleRedaction.verifier(try await redacteur.rediger(brut), brut: brut) {
            case let .success(redaction): return (redaction, .redigee)
            case let .failure(rejet): return (nil, .rejetee(rejet.raison))
            }
        } catch {
            return (nil, .rejetee((error as? any ErreurSansContenu)?.description ?? String(describing: type(of: error))))
        }
    }
}
