import Foundation
import Testing
@testable import VocalCore

/// Transcripteur dont la préparation fait disparaître un mémo, comme une éviction iCloud au mauvais moment.
struct TranscripteurQuiEvince: Transcripteur {
    let memo: URL
    func preparer() async throws { try FileManager.default.removeItem(at: memo) }
    func transcrire(_ audio: URL) async throws -> String { "bonjour ceci est un mémo" }
}

@Suite("Commande passage : reprises")
struct PassageRepriseTests {
    /// Prépare l'état laissé par une coupure entre l'écriture du fichier temporaire et son renommage.
    func coupure(_ banc: Banc, temporaireEncoreLa: Bool) async throws {
        _ = try await banc.passage()
        let memo = try banc.deposer(sous: "20261009 132121-7EB013BF.m4a")
        let valeurs = try memo.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let base = try BaseEtat(banc.etat)
        var ligne = try base.inserer(FichierObserve(url: memo, nom: memo.lastPathComponent, taille: Int64(valeurs.fileSize!),
                                                    modification: valeurs.contentModificationDate!.timeIntervalSince1970),
                                     statut: .vu, maintenant: banc.horloge.maintenant().timeIntervalSince1970)
        let temporaire = try EcritureNote.preparer("note écrite avant la coupure\n", dans: banc.inbox)
        ligne.ecriture = .init(temporaire: temporaire.lastPathComponent, nomDeBase: "2026-10-09 13h21 - Vocal - Titre", statut: .traite)
        try base.enregistrer(ligne, maintenant: banc.horloge.maintenant().timeIntervalSince1970)
        if !temporaireEncoreLa {
            _ = try EcritureNote.publier(temporaire, nomDeBase: "2026-10-09 13h21 - Vocal - Titre", dans: banc.inbox)
        }
        banc.horloge.avancer(300)
    }

    @Test("après une coupure avant le renommage, la note préparée est publiée sans nouvelle transcription")
    func repriseAvantRenommage() async throws {
        let banc = try Banc()
        try await coupure(banc, temporaireEncoreLa: true)
        let enPanne = TranscripteurEnPanne()

        _ = try await banc.passage(enPanne)

        #expect(try banc.notes() == ["2026-10-09 13h21 - Vocal - Titre.md"])
        #expect(try String(contentsOf: banc.inbox.appendingPathComponent("2026-10-09 13h21 - Vocal - Titre.md"), encoding: .utf8)
                == "note écrite avant la coupure\n")
        #expect(enPanne.appels == 0)
        #expect(try RapportEtat.texte(banc.etat, fuseau: paris).contains("traités : 1\n  n°1, le 2027-01-15 09:"))
    }

    @Test("après une coupure juste après le renommage, aucune deuxième note n'est écrite")
    func repriseApresRenommage() async throws {
        let banc = try Banc()
        try await coupure(banc, temporaireEncoreLa: false)
        let enPanne = TranscripteurEnPanne()

        _ = try await banc.passage(enPanne)
        banc.horloge.avancer(300)
        _ = try await banc.passage(enPanne)

        #expect(try banc.notes() == ["2026-10-09 13h21 - Vocal - Titre.md"])
        #expect(enPanne.appels == 0)
    }

    @Test("un fichier temporaire de Vocal resté dans l'inbox est retiré")
    func temporaireOrphelin() async throws {
        let banc = try Banc()
        _ = try await banc.passage()
        _ = try EcritureNote.preparer("reste", dans: banc.inbox)
        banc.horloge.avancer(300)
        _ = try await banc.passage()
        #expect(try banc.notes().isEmpty)
    }

    @Test("un mémo qui disparaît juste avant sa transcription ne compte pas comme un échec")
    func audioDisparu() async throws {
        let banc = try Banc()
        _ = try await banc.passage()
        for _ in 1...3 {
            let memo = try banc.deposer(sous: "20261009 132121-7EB013BF.m4a")
            banc.horloge.avancer(300)
            let bilan = try await banc.passage(TranscripteurQuiEvince(memo: memo))
            #expect(bilan.notes.isEmpty)
            #expect(bilan.echecs == 0)
        }
        try banc.deposer(sous: "20261009 132121-7EB013BF.m4a")
        banc.horloge.avancer(300)
        _ = try await banc.passage()
        #expect(try banc.notes() == ["2026-10-09 13h21 - Vocal - Vocal sans titre.md"])
    }

    @Test("un sous-dossier illisible ne fait pas oublier ses mémos ni leurs tentatives")
    func sousDossierIllisible() async throws {
        let banc = try Banc()
        _ = try await banc.passage()
        try banc.deposer(sous: "Dossier/20261009 132121-7EB013BF.m4a")
        let sousDossier = banc.enregistrements.appendingPathComponent("Dossier")
        let enPanne = TranscripteurEnPanne()
        banc.horloge.avancer(300)
        _ = try await banc.passage(enPanne)

        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: sousDossier.path)
        banc.horloge.avancer(300)
        let pendant = try await banc.passage(enPanne)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sousDossier.path)
        #expect(pendant.notes.isEmpty)

        for _ in 1...2 {
            banc.horloge.avancer(300)
            _ = try await banc.passage(enPanne)
        }
        #expect(try banc.notes() == ["2026-10-09 13h21 - Vocal - Vocal transcription impossible.md"])
        #expect(enPanne.appels == 3)
    }

    @Test("un état amorcé sur un dossier refuse un autre dossier des enregistrements")
    func autreDossier() async throws {
        let banc = try Banc()
        _ = try await banc.passage()
        let copie = banc.racine.appendingPathComponent("Copie", isDirectory: true)
        try FileManager.default.createDirectory(at: copie, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixtures.appendingPathComponent("watch.m4a"),
                                         to: copie.appendingPathComponent("20261009 132121-7EB013BF.m4a"))
        let ailleurs = Emplacements(enregistrements: copie, inbox: banc.inbox, etat: banc.etat, journal: banc.journal)

        await #expect(throws: ErreurPassage.autreDossier) {
            try await Passage(transcripteur: TranscripteurFactice(texte: "texte"), horloge: banc.horloge, fuseau: paris).executer(ailleurs)
        }
        #expect(try banc.notes().isEmpty)
    }
}
