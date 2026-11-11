import Foundation
import Testing
import VocalCore

@Suite("Base du Dictaphone dans le passage")
struct DictaphoneTests {
    @Test("le nom du mémo vient de la base, à défaut du titre inscrit dans le fichier, sinon du nom du fichier")
    func nomDuMemo() async throws {
        let banc = try Banc()
        _ = try await banc.passage()
        try banc.deposer(sous: "20261009 132121-7EB013BF.m4a")
        try banc.deposer("iphone.qta", sous: "20260702 191614-C4BBE1A5.qta")
        try banc.deposer("sans-meta.m4a", sous: "20260115 080000-ABCDEF12.m4a")
        try fabriquerBaseDictaphone(dans: banc.enregistrements, [
            LigneDictaphone(fichier: "20261009 132121-7EB013BF.m4a", titre: "Idée \"vélo\" du matin"),
            LigneDictaphone(fichier: "20260702 191614-C4BBE1A5.qta", titre: nil),
        ])
        banc.horloge.avancer(300)

        _ = try await banc.passage()

        let textes = try banc.notes().map { try String(contentsOf: banc.inbox.appendingPathComponent($0), encoding: .utf8) }
        #expect(textes.contains { $0.contains(#"memo: "Idée \"vélo\" du matin""#) })
        #expect(textes.contains { $0.contains(#"memo: "Rue des Essais 12""#) })
        #expect(textes.contains { $0.contains(#"memo: "20260115 080000-ABCDEF12""#) })
        let journal = try String(contentsOf: banc.journal, encoding: .utf8)
        #expect(!journal.contains("vélo"))
    }

    @Test("un mémo dans « Supprimés récemment » ne produit pas de note ; récupéré, il est traité")
    func memoSupprime() async throws {
        let banc = try Banc()
        _ = try await banc.passage()
        try banc.deposer(sous: "20261009 132121-7EB013BF.m4a")
        try fabriquerBaseDictaphone(dans: banc.enregistrements, [
            LigneDictaphone(fichier: "20261009 132121-7EB013BF.m4a", titre: "Idée", supprimeLe: 815_000_000),
        ])
        banc.horloge.avancer(300)
        let pendant = try await banc.passage()
        banc.horloge.avancer(300)
        _ = try await banc.passage()
        #expect(pendant.notes.isEmpty && pendant.enAttente == 0 && pendant.echecs == 0)
        #expect(try banc.notes().isEmpty)

        try marquerSupprime(dans: banc.enregistrements, "20261009 132121-7EB013BF.m4a", le: nil)
        banc.horloge.avancer(300)
        let apres = try await banc.passage()
        #expect(apres.notes.count == 1)
    }

    @Test("une base absente, illisible ou au schéma différent ne fait pas échouer le passage ; le journal le dit",
          arguments: [
            ("absente", nil),
            ("illisible (code 26)", "pas une base"),
            ("schéma différent : table ZCLOUDRECORDING absente", "CREATE TABLE ZAUTRE (ZPATH VARCHAR)"),
            ("schéma différent : colonne ZEVICTIONDATE absente",
             "CREATE TABLE ZCLOUDRECORDING (Z_PK INTEGER PRIMARY KEY, ZPATH VARCHAR, ZENCRYPTEDTITLE VARCHAR, ZUNIQUEID VARCHAR)"),
          ] as [(String, String?)])
    func baseInutilisable(raison: String, contenuDeLaBase: String?) async throws {
        let banc = try Banc()
        _ = try await banc.passage()
        try banc.deposer("iphone.qta", sous: "20260702 191614-C4BBE1A5.qta")
        switch contenuDeLaBase {
        case nil: break
        case let schema? where schema.hasPrefix("CREATE"):
            try fabriquerBaseDictaphone(dans: banc.enregistrements, [LigneDictaphone(fichier: "20260702 191614-C4BBE1A5.qta", titre: "Autre")],
                                        schema: schema)
        case let texte?:
            try Data(texte.utf8).write(to: banc.enregistrements.appendingPathComponent("CloudRecordings.db"))
        }
        banc.horloge.avancer(300)

        let bilan = try await banc.passage()

        #expect(bilan.notes.count == 1)
        let note = try String(contentsOf: try #require(bilan.notes.first).url, encoding: .utf8)
        #expect(note.contains(#"memo: "Rue des Essais 12""#))
        let journal = try String(contentsOf: banc.journal, encoding: .utf8)
        #expect(journal.contains("base du Dictaphone \(raison) : noms des mémos et suppressions inconnus"))
    }

    @Test("un mémo encore remplacé par un fichier iCloud attend sans échec, et il est traité quand l'audio arrive")
    func audioPasEncoreTelecharge() async throws {
        let banc = try Banc()
        _ = try await banc.passage()
        try Data().write(to: banc.enregistrements.appendingPathComponent(".20261105 090000-22222222.m4a.icloud"))
        try fabriquerBaseDictaphone(dans: banc.enregistrements, [LigneDictaphone(fichier: "20261105 090000-22222222.m4a", titre: "Course")])
        banc.horloge.avancer(300)
        let avant = try await banc.passage(TranscripteurQuiEchoue())
        #expect(avant.notes.isEmpty && avant.echecs == 0)

        try FileManager.default.removeItem(at: banc.enregistrements.appendingPathComponent(".20261105 090000-22222222.m4a.icloud"))
        try banc.deposer(sous: "20261105 090000-22222222.m4a")
        banc.horloge.avancer(300)
        let apres = try await banc.passage()
        #expect(apres.notes.count == 1)
    }

    @Test("la base du Dictaphone est lue sans que rien ne change dans le dossier, ni elle ni ses fichiers -wal et -shm",
          arguments: [true, false])
    func baseNonModifiee(avecFichiersAnnexes: Bool) async throws {
        let banc = try Banc()
        _ = try await banc.passage()
        try banc.deposer(sous: "20261009 132121-7EB013BF.m4a")
        try fabriquerBaseDictaphone(dans: banc.enregistrements, [LigneDictaphone(fichier: "20261009 132121-7EB013BF.m4a", titre: "Idée")])
        if !avecFichiersAnnexes {
            for suffixe in ["-wal", "-shm"] {
                try? FileManager.default.removeItem(at: banc.enregistrements.appendingPathComponent("CloudRecordings.db" + suffixe))
            }
        }
        let avant = try instantane(banc.enregistrements)
        banc.horloge.avancer(300)

        _ = try await banc.passage()

        let notes = try banc.notes()
        #expect(notes.count == 1)
        #expect(try String(contentsOf: banc.inbox.appendingPathComponent(try #require(notes.first)), encoding: .utf8).contains(#"memo: "Idée""#))
        let apres = try instantane(banc.enregistrements)
        #expect(apres == avant)
    }
}
