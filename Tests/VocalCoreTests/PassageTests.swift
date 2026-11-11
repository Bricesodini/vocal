import Foundation
import Synchronization
import Testing
import VocalCore

/// Horloge simulée : `attendre` avance le temps sans dormir, et peut lancer une action pendant l'attente.
final class HorlogeSimulee: Horloge, Sendable {
    private let instant = Mutex(Date(timeIntervalSince1970: 1_800_000_000))
    private let action = Mutex<(@Sendable () -> Void)?>(nil)
    func maintenant() -> Date { instant.withLock { $0 } }
    func attendre(_ secondes: TimeInterval) async { instant.withLock { $0 += secondes }; action.withLock { $0 }?() }
    func avancer(_ secondes: TimeInterval) { instant.withLock { $0 += secondes } }
    /// Action lancée à chaque attente, par exemple pour modifier un mémo en cours de synchronisation.
    func pendantAttente(_ a: (@Sendable () -> Void)?) { action.withLock { $0 = a } }
}

/// Banc d'essai d'un passage : dossier des enregistrements, inbox, état et journal sous une même racine.
struct Banc {
    let racine: URL
    let horloge = HorlogeSimulee()
    var enregistrements: URL { racine.appendingPathComponent("Group Containers/Recordings", isDirectory: true) }
    var inbox: URL { racine.appendingPathComponent("0 INBOX", isDirectory: true) }
    var etat: URL { racine.appendingPathComponent("Etat", isDirectory: true) }
    var journal: URL { racine.appendingPathComponent("Logs/vocal.log") }
    var emplacements: Emplacements {
        Emplacements(enregistrements: enregistrements, inbox: inbox, etat: etat, journal: journal)
    }

    init() throws {
        racine = try dossierTemporaire()
        try FileManager.default.createDirectory(at: enregistrements, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
    }

    /// Dépose un mémo de synthèse dans le dossier des enregistrements, sous un nom du Dictaphone.
    @discardableResult
    func deposer(_ fixture: String = "watch.m4a", sous nom: String) throws -> URL {
        let cible = enregistrements.appendingPathComponent(nom)
        try FileManager.default.createDirectory(at: cible.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixtures.appendingPathComponent(fixture), to: cible)
        return cible
    }

    func passage(_ transcripteur: any Transcripteur = TranscripteurFactice(texte: "bonjour ceci est un mémo"),
                 redacteur: (any Redacteur)? = nil) async throws -> BilanPassage {
        try await Passage(transcripteur: transcripteur, redacteur: redacteur, horloge: horloge, fuseau: paris)
            .executer(emplacements)
    }

    func notes() throws -> [String] { try contenu(inbox) }
}

@Suite("Commande passage")
struct PassageTests {
    @Test("au premier passage, les mémos présents sont ignorés et aucune note n'est écrite")
    func amorcage() async throws {
        let banc = try Banc()
        try banc.deposer(sous: "20261009 132121-7EB013BF.m4a")
        try banc.deposer("iphone.qta", sous: "Dossier/20260702 191614-C4BBE1A5.qta")
        try Data().write(to: banc.enregistrements.appendingPathComponent(".20261105 090000-22222222.m4a.icloud"))

        let premier = try await banc.passage()
        #expect(premier.amorcage == 3)
        #expect(premier.notes.isEmpty)
        #expect(try banc.notes().isEmpty)

        // Le mémo qui n'était qu'un remplacement iCloud arrive : il était déjà présent, il reste ignoré.
        try banc.deposer(sous: "20261105 090000-22222222.m4a")
        banc.horloge.avancer(300)
        let second = try await banc.passage()
        #expect(second.amorcage == nil)
        #expect(second.notes.isEmpty)
        #expect(try banc.notes().isEmpty)
    }

    @Test("un mémo nouveau, stable pendant 12 secondes, devient une note dans le même passage")
    func nouveauMemoStable() async throws {
        let banc = try Banc()
        _ = try await banc.passage()
        try banc.deposer(sous: "20261009 132121-7EB013BF.m4a")
        banc.horloge.avancer(300)
        let debut = banc.horloge.maintenant()

        let bilan = try await banc.passage()

        #expect(bilan.notes.map(\.url.lastPathComponent) == ["2026-10-09 13h21 - Vocal - Vocal sans titre.md"])
        #expect(banc.horloge.maintenant().timeIntervalSince(debut) >= 12)
        #expect(try banc.notes() == ["2026-10-09 13h21 - Vocal - Vocal sans titre.md"])
        let note = try #require(bilan.notes.first?.url)
        let texte = try String(contentsOf: note, encoding: .utf8)
        #expect(texte.contains("## Transcription brute\n\nbonjour ceci est un mémo\n"))
    }

    @Test("un mémo qui change entre deux observations n'est pas traité ; il l'est une fois stable")
    func memoEnCoursDeSynchronisation() async throws {
        let banc = try Banc()
        _ = try await banc.passage()
        let memo = try banc.deposer(sous: "20261009 132121-7EB013BF.m4a")
        banc.horloge.avancer(300)
        // Pendant l'attente, iCloud réécrit le fichier : sa date de modification change.
        banc.horloge.pendantAttente {
            let date = Date().addingTimeInterval(Double.random(in: 1...1000))
            try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: memo.path)
        }
        let pendant = try await banc.passage()
        #expect(pendant.notes.isEmpty)
        #expect(pendant.enAttente == 1)
        #expect(try banc.notes().isEmpty)

        banc.horloge.pendantAttente(nil)
        banc.horloge.avancer(300)
        let apres = try await banc.passage()
        #expect(apres.notes.count == 1)
        #expect(apres.enAttente == 0)
    }

    @Test("relancer le passage, ou en lancer un autre, ne donne jamais deux notes pour un mémo")
    func unSeulTraitement() async throws {
        let banc = try Banc()
        _ = try await banc.passage()
        try banc.deposer(sous: "20261009 132121-7EB013BF.m4a")
        try banc.deposer(sous: "Sous dossier/20261009 132121-7EB013BF.m4a")
        for _ in 0..<3 {
            banc.horloge.avancer(300)
            _ = try await banc.passage()
        }
        #expect(try banc.notes().count == 1)
    }

    @Test("un échec de transcription est réessayé ; au troisième, une note le signale et le mémo passe en échec")
    func troisEchecs() async throws {
        let banc = try Banc()
        _ = try await banc.passage()
        try banc.deposer(sous: "20261009 132121-7EB013BF.m4a")
        let enPanne = TranscripteurEnPanne()

        for essai in 1...2 {
            banc.horloge.avancer(300)
            let bilan = try await banc.passage(enPanne)
            #expect(bilan.notes.isEmpty, "passage \(essai)")
            #expect(bilan.enAttente == 1, "passage \(essai)")
        }
        banc.horloge.avancer(300)
        let troisieme = try await banc.passage(enPanne)
        #expect(troisieme.echecs == 1)
        #expect(troisieme.enAttente == 0)
        #expect(try banc.notes() == ["2026-10-09 13h21 - Vocal - Vocal transcription impossible.md"])
        let note = try #require(troisieme.notes.first?.url)
        let texte = try String(contentsOf: note, encoding: .utf8)
        #expect(texte == """
        ---
        type: note-vocale
        date: 2026-10-09
        source: vocal
        statut: à traiter
        duree: "0:06"
        memo: "20261009 132121-7EB013BF"
        appareil: watch
        llm: aucun
        ---

        # Vocal transcription impossible

        La transcription de ce mémo a échoué trois fois. L'audio reste intact dans le Dictaphone.

        """)

        banc.horloge.avancer(300)
        let quatrieme = try await banc.passage(enPanne)
        #expect(quatrieme.notes.isEmpty)
        #expect(enPanne.appels == 3)
        #expect(try banc.notes().count == 1)
    }

    @Test("un fichier qui n'est pas de l'audio compte comme un échec ; sa note prend la date de son nom")
    func audioIllisible() async throws {
        let banc = try Banc()
        _ = try await banc.passage()
        try Data("pas de l'audio".utf8).write(to: banc.enregistrements.appendingPathComponent("20260115 080000-ABCDEF12.m4a"))
        for _ in 1...3 {
            banc.horloge.avancer(300)
            _ = try await banc.passage()
        }
        #expect(try banc.notes() == ["2026-01-15 08h00 - Vocal - Vocal transcription impossible.md"])
    }

    @Test("un transcripteur pas prêt arrête le passage sans compter d'échec pour les mémos")
    func transcripteurPasPret() async throws {
        let banc = try Banc()
        _ = try await banc.passage()
        try banc.deposer(sous: "20261009 132121-7EB013BF.m4a")
        for _ in 1...3 {
            banc.horloge.avancer(300)
            await #expect(throws: TranscripteurPasPret.ModeleAbsent.self) { try await banc.passage(TranscripteurPasPret()) }
        }
        #expect(try banc.notes().isEmpty)

        banc.horloge.avancer(300)
        let bilan = try await banc.passage()
        #expect(bilan.notes.map(\.url.lastPathComponent) == ["2026-10-09 13h21 - Vocal - Vocal sans titre.md"])
    }

    @Test("deux passages simultanés sont impossibles : le second s'arrête sans rien faire")
    func verrou() async throws {
        let banc = try Banc()
        _ = try await banc.passage()
        try banc.deposer(sous: "20261009 132121-7EB013BF.m4a")
        banc.horloge.avancer(300)
        let bloque = TranscripteurBloque()

        let premier = Task { try await banc.passage(bloque) }
        var entree = bloque.entree.stream.makeAsyncIterator()
        await entree.next()
        await #expect(throws: ErreurPassage.dejaEnCours) { try await banc.passage() }
        bloque.liberation.continuation.yield()

        #expect(try await premier.value.notes.count == 1)
        #expect(try banc.notes().count == 1)
    }

    @Test("le parcours descend dans les sous-dossiers et ignore le caché, les remplacements iCloud et le reste")
    func parcours() async throws {
        let banc = try Banc()
        _ = try await banc.passage()
        try banc.deposer(sous: "20261009 132121-7EB013BF.m4a")
        try banc.deposer("iphone.qta", sous: "Dossier/Sous-dossier/20260702 191614-C4BBE1A5.qta")
        try banc.deposer(sous: ".Trash/20261101 080000-11111111.m4a")
        try banc.deposer(sous: ".20261102 080000-33333333.m4a")
        try Data().write(to: banc.enregistrements.appendingPathComponent(".20261105 090000-22222222.m4a.icloud"))
        try Data("x".utf8).write(to: banc.enregistrements.appendingPathComponent("notes.txt"))
        banc.horloge.avancer(300)

        let bilan = try await banc.passage()

        #expect(try banc.notes() == ["2026-07-02 19h16 - Vocal - Vocal sans titre.md", "2026-10-09 13h21 - Vocal - Vocal sans titre.md"])
        #expect(bilan.enAttente == 0)
    }

    @Test("le passage n'écrit que dans l'inbox, son état et son journal, et ne touche jamais aux enregistrements")
    func aucuneEcritureAilleurs() async throws {
        let banc = try Banc()
        try banc.deposer(sous: "20261001 080000-AAAAAAAA.m4a")
        _ = try await banc.passage()
        try banc.deposer(sous: "20261009 132121-7EB013BF.m4a")
        try banc.deposer("iphone.qta", sous: "Dossier/20260702 191614-C4BBE1A5.qta")
        try Data("pas de l'audio".utf8).write(to: banc.enregistrements.appendingPathComponent("20260115 080000-ABCDEF12.m4a"))
        let avant = try instantane(banc.racine)

        for _ in 1...4 {
            banc.horloge.avancer(300)
            _ = try await banc.passage(redacteur: RedacteurFactice(.success(redactionValide)))
        }

        let apres = try instantane(banc.racine)
        let hors = { (chemin: String) in !["0 INBOX/", "Etat/", "Logs/"].contains { chemin.hasPrefix($0) } }
        #expect(apres.filter { hors($0.key) } == avant.filter { hors($0.key) })
        #expect(apres.keys.filter { $0.hasPrefix("0 INBOX/") }.allSatisfy { $0.hasSuffix(".md") && !$0.contains("/.") })
        #expect(apres.keys.filter { $0.hasPrefix("0 INBOX/") }.count == 3)
        #expect(apres.keys.filter { $0.hasPrefix("Etat/cache/") }.isEmpty)
    }

    @Test("sans dossier d'inbox, le passage s'arrête sans rien écrire")
    func inboxAbsente() async throws {
        let banc = try Banc()
        try FileManager.default.removeItem(at: banc.inbox)
        try banc.deposer(sous: "20261009 132121-7EB013BF.m4a")

        await #expect(throws: ErreurPassage.inboxAbsente(banc.inbox.path)) { try await banc.passage() }
        #expect(try contenu(banc.racine) == ["Group Containers"])
    }

    @Test("le journal a une ligne par mémo, repéré par son identifiant, sans texte de mémo ni de rédaction")
    func journalSansTexte() async throws {
        let banc = try Banc()
        _ = try await banc.passage()
        try banc.deposer(sous: "20261009 132121-7EB013BF.m4a")
        try banc.deposer("iphone.qta", sous: "20260702 191614-C4BBE1A5.qta")
        banc.horloge.avancer(300)
        _ = try await banc.passage(redacteur: RedacteurFactice(.success(redactionValide)))
        try banc.deposer("silence-ipad.m4a", sous: "20261101 090000-44444444.m4a")
        banc.horloge.avancer(300)
        _ = try await banc.passage(TranscripteurEnPanne())

        let journal = try String(contentsOf: banc.journal, encoding: .utf8)
        let lignes = journal.split(separator: "\n")
        #expect(lignes.filter { $0.contains(": traité (") }.count == 2)
        #expect(lignes.filter { $0.contains("échec de transcription 1/3") }.count == 1)
        #expect(lignes.contains { $0.contains("llm maison/modele-test") })
        #expect(lignes.contains { $0.contains("mémo n°1 (20260702 191614-C4BBE1A5) : traité (") })
        for interdit in ["bonjour", "mémo pour", "Rendez-vous", "parler SEO", "Silence", "Rue des Essais",
                         "Vocal sans titre", "Recordings", "INBOX", ".m4a", ".qta"] {
            #expect(!journal.contains(interdit), "le journal contient « \(interdit) »")
        }
    }

    @Test("état liste les mémos traités, en attente et en échec, et les derniers passages")
    func etat() async throws {
        let banc = try Banc()
        try banc.deposer(sous: "20261001 080000-AAAAAAAA.m4a")
        _ = try await banc.passage()
        try banc.deposer(sous: "20261009 132121-7EB013BF.m4a")
        banc.horloge.avancer(300)
        _ = try await banc.passage()
        try banc.deposer("iphone.qta", sous: "20260702 191614-C4BBE1A5.qta")
        banc.horloge.avancer(300)
        _ = try await banc.passage(TranscripteurEnPanne())

        let rapport = try RapportEtat.texte(banc.etat, fuseau: paris)

        #expect(rapport.contains("ignorés à l'amorçage : 1\n"))
        #expect(rapport.contains("traités : 1\n  n°2, le 2027-01-15 09:"))
        #expect(rapport.contains(" : 2026-10-09 13h21 - Vocal - Vocal sans titre.md\n"))
        #expect(rapport.contains("en attente : 1\n  n°3, 20260702 191614-C4BBE1A5.qta, vu le 2027-01-15 09:"))
        #expect(rapport.contains(", 1 tentative(s) échouée(s)\n"))
        #expect(rapport.contains("en échec : 0\n"))
        #expect(rapport.contains("derniers passages (3 en tout) :\n"))
        #expect(rapport.contains(" : 0 note(s), 1 en attente, 0 échec(s)\n"))
        #expect(try RapportEtat.texte(banc.racine.appendingPathComponent("vide"), fuseau: paris) == "aucun passage : l'état est vide\n")
    }
}

let redactionValide = Redaction(titre: "Rendez-vous SEO", resume: "Un mémo pour parler SEO.",
                                texte: "Bonjour, ceci est un mémo.")

/// Taille et date de modification de chaque fichier sous une racine, par chemin relatif.
func instantane(_ racine: URL) throws -> [String: String] {
    var resultat: [String: String] = [:]
    let fm = FileManager.default
    for chemin in try fm.subpathsOfDirectory(atPath: racine.path) {
        let attributs = try fm.attributesOfItem(atPath: racine.appendingPathComponent(chemin).path)
        guard attributs[.type] as? FileAttributeType != .typeDirectory else { continue }
        resultat[chemin] = "\(attributs[.size] ?? 0) \((attributs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
    }
    return resultat
}

/// Transcripteur qui signale son entrée, puis attend qu'on le libère.
final class TranscripteurBloque: Transcripteur, Sendable {
    let entree = AsyncStream<Void>.makeStream()
    let liberation = AsyncStream<Void>.makeStream()
    func transcrire(_ audio: URL) async throws -> String {
        entree.continuation.yield()
        for await _ in liberation.stream { break }
        return "bonjour ceci est un mémo"
    }
}


@Suite("Mémos sans parole")
struct MemosSansParoleTests {
    @Test("un mémo sans aucune parole détectée, comme un appui involontaire, est réessayé puis écarté sans note")
    func sansParole() async throws {
        let banc = try Banc()
        _ = try await banc.passage()
        try banc.deposer(sous: "20261111 090554-DFE0C212.m4a")
        var bilans: [BilanPassage] = []
        for _ in 1...3 {
            banc.horloge.avancer(300)
            bilans.append(try await banc.passage(TranscripteurFactice(texte: "  ")))
        }
        banc.horloge.avancer(300)
        let apres = try await banc.passage(TranscripteurQuiEchoue())

        #expect(try banc.notes().isEmpty)
        #expect(bilans.map(\.echecs) == [0, 0, 0])
        #expect(bilans.map(\.enAttente) == [1, 1, 0])
        #expect(apres.enAttente == 0)
        let rapport = try RapportEtat.texte(banc.etat, fuseau: paris)
        #expect(rapport.contains("sans parole, écartés : 1\n"))
        #expect(rapport.contains("en échec : 0\n"))
        let journal = try String(contentsOf: banc.journal, encoding: .utf8)
        #expect(journal.contains("mémo n°1 (20261111 090554-DFE0C212) : aucune parole détectée 1/3, réessai au prochain passage"))
        #expect(journal.contains("mémo n°1 (20261111 090554-DFE0C212) : aucune parole détectée 3/3, mémo écarté sans note"))
    }
}
