import Foundation
import Testing
import VocalCore

extension Banc {
    func traiter(_ designation: String, encore: Bool = false,
                 _ transcripteur: any Transcripteur = TranscripteurFactice(texte: "bonjour ceci est un mémo")) async throws -> NoteEcrite {
        try await Passage(transcripteur: transcripteur, horloge: horloge, fuseau: paris)
            .traiter(designation, encore: encore, emplacements)
    }

    func rapport() throws -> String { try RapportEtat.texte(etat, fuseau: paris) }
}

@Suite("Commande traiter")
struct TraiterTests {
    @Test("un mémo ignoré à l'amorçage est traité à la demande, une seule fois sauf demande explicite")
    func memoIgnore() async throws {
        let banc = try Banc()
        try banc.deposer(sous: "20261009 132121-7EB013BF.m4a")
        _ = try await banc.passage()

        let note = try await banc.traiter("20261009 132121-7EB013BF")
        #expect(note.url.lastPathComponent == "2026-10-09 13h21 - Vocal - Vocal sans titre.md")
        #expect(try banc.rapport().contains("traités : 1\n"))
        #expect(try banc.rapport().contains("ignorés à l'amorçage : 0\n"))

        await #expect(throws: ErreurTraiter.dejaTraite("20261009 132121-7EB013BF.m4a")) {
            try await banc.traiter("20261009 132121-7EB013BF.m4a")
        }
        #expect(try banc.notes().count == 1)

        let encore = try await banc.traiter("20261009 132121-7EB013BF.m4a", encore: true)
        #expect(encore.url.lastPathComponent == "2026-10-09 13h21 - Vocal - Vocal sans titre (2).md")
        #expect(try banc.notes().count == 2)
        let journal = try String(contentsOf: banc.journal, encoding: .utf8)
        #expect(journal.contains("mémo n°1 (20261009 132121-7EB013BF) : traité à la demande ("))
    }

    @Test("un mémo se désigne par le titre de la base ; un titre partagé liste les mémos sans rien écrire")
    func parTitre() async throws {
        let banc = try Banc()
        try banc.deposer(sous: "20261009 132121-7EB013BF.m4a")
        try banc.deposer("iphone.qta", sous: "20260702 191614-C4BBE1A5.qta")
        try banc.deposer(sous: "20261101 080000-11111111.m4a")
        try fabriquerBaseDictaphone(dans: banc.enregistrements, [
            LigneDictaphone(fichier: "20261009 132121-7EB013BF.m4a", titre: "Idée vélo"),
            LigneDictaphone(fichier: "20260702 191614-C4BBE1A5.qta", titre: "Course"),
            LigneDictaphone(fichier: "20261101 080000-11111111.m4a", titre: "Course"),
        ])
        _ = try await banc.passage()

        let note = try await banc.traiter("Idée vélo")
        #expect(try String(contentsOf: note.url, encoding: .utf8).contains(#"memo: "Idée vélo""#))

        await #expect(throws: ErreurTraiter.plusieurs(["20260702 191614-C4BBE1A5.qta", "20261101 080000-11111111.m4a"])) {
            try await banc.traiter("Course")
        }
        #expect(try banc.notes().count == 1)
        let journal = try String(contentsOf: banc.journal, encoding: .utf8)
        for titre in ["Idée", "vélo", "Course"] { #expect(!journal.contains(titre), "le journal contient « \(titre) »") }
    }

    @Test("un mémo introuvable, supprimé récemment ou pas encore téléchargé est refusé sans rien écrire")
    func refus() async throws {
        let banc = try Banc()
        try banc.deposer(sous: "20261009 132121-7EB013BF.m4a")
        try Data().write(to: banc.enregistrements.appendingPathComponent(".20261105 090000-22222222.m4a.icloud"))
        try fabriquerBaseDictaphone(dans: banc.enregistrements, [
            LigneDictaphone(fichier: "20261009 132121-7EB013BF.m4a", titre: "Idée", supprimeLe: 815_000_000),
            LigneDictaphone(fichier: "20261105 090000-22222222.m4a", titre: "Course"),
            LigneDictaphone(fichier: "20261106 090000-55555555.m4a", titre: "Jeté", supprimeLe: 815_000_000),
            LigneDictaphone(fichier: "20261107 090000-66666666.m4a", titre: "Pas arrivé"),
            LigneDictaphone(fichier: "20261108 090000-77777777.m4a", titre: "Idée"),
        ])
        _ = try await banc.passage()

        await #expect(throws: ErreurTraiter.introuvable("Inconnu")) { try await banc.traiter("Inconnu") }
        // « Idée » : un mémo supprimé et un autre dont l'audio n'est pas arrivé ; seul le second compte.
        await #expect(throws: ErreurTraiter.pasTelecharge("20261108 090000-77777777.m4a")) { try await banc.traiter("Idée") }
        await #expect(throws: ErreurTraiter.supprime("20261106 090000-55555555.m4a")) { try await banc.traiter("Jeté") }
        await #expect(throws: ErreurTraiter.pasTelecharge("20261107 090000-66666666.m4a")) { try await banc.traiter("pas arrive") }
        await #expect(throws: ErreurTraiter.supprime("20261009 132121-7EB013BF.m4a")) {
            try await banc.traiter("20261009 132121-7EB013BF")
        }
        await #expect(throws: ErreurTraiter.pasTelecharge("20261105 090000-22222222.m4a")) { try await banc.traiter("Course") }
        await #expect(throws: ErreurTraiter.pasTelecharge("20261105 090000-22222222.m4a")) {
            try await banc.traiter("20261105 090000-22222222.m4a")
        }
        #expect(try banc.notes().isEmpty)
    }

    @Test("avant tout passage, traiter refuse : l'amorçage doit d'abord marquer les mémos présents")
    func avantAmorcage() async throws {
        let banc = try Banc()
        try banc.deposer(sous: "20261009 132121-7EB013BF.m4a")

        await #expect(throws: ErreurTraiter.pasAmorce) { try await banc.traiter("20261009 132121-7EB013BF") }
        #expect(try banc.notes().isEmpty)
    }

    @Test("un mémo traité à la demande n'est pas retraité par le passage suivant")
    func puisPassage() async throws {
        let banc = try Banc()
        _ = try await banc.passage()
        try banc.deposer(sous: "20261009 132121-7EB013BF.m4a")
        _ = try await banc.traiter("20261009 132121-7EB013BF")
        banc.horloge.avancer(300)

        let bilan = try await banc.passage()

        #expect(bilan.notes.isEmpty)
        #expect(try banc.notes().count == 1)
    }

    @Test("un échec de transcription à la demande est signalé, sans note ni changement d'état")
    func echecDeTranscription() async throws {
        let banc = try Banc()
        try banc.deposer(sous: "20261009 132121-7EB013BF.m4a")
        _ = try await banc.passage()
        let avant = try banc.rapport()

        await #expect(throws: TranscripteurEnPanne.Panne.self) {
            try await banc.traiter("20261009 132121-7EB013BF", TranscripteurEnPanne())
        }
        #expect(try banc.notes().isEmpty)
        #expect(try banc.rapport() == avant)
    }
}
