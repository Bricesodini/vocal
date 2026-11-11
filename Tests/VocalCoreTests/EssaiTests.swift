import Foundation
import Testing
import VocalCore

@Suite("Commande essai")
struct EssaiTests {
    @Test("un mémo Watch donne une note complète, nommée par sa date locale")
    func memoWatch() async throws {
        let destination = try dossierTemporaire()
        let essai = Essai(transcripteur: TranscripteurFactice(texte: "Bonjour, ceci est un test."), fuseau: paris)

        let note = try await essai.executer(audio: fixtures.appendingPathComponent("watch.m4a"), destination: destination).url

        #expect(note.lastPathComponent == "2026-10-09 13h21 - Vocal - Vocal sans titre.md")
        #expect(try String(contentsOf: note, encoding: .utf8) == """
        ---
        type: note-vocale
        date: 2026-10-09
        source: vocal
        statut: à traiter
        duree: "0:06"
        memo: "watch"
        appareil: watch
        llm: aucun
        ---

        # Vocal sans titre

        ## Transcription brute

        Bonjour, ceci est un test.

        """)
        #expect(try contenu(destination) == ["2026-10-09 13h21 - Vocal - Vocal sans titre.md"])
    }

    @Test("une note existante n'est jamais écrasée : la suivante reçoit un suffixe")
    func collision() async throws {
        let destination = try dossierTemporaire()
        let audio = fixtures.appendingPathComponent("watch.m4a")

        let premiere = try await Essai(transcripteur: TranscripteurFactice(texte: "premier texte"), fuseau: paris)
            .executer(audio: audio, destination: destination).url
        let deuxieme = try await Essai(transcripteur: TranscripteurFactice(texte: "deuxième texte"), fuseau: paris)
            .executer(audio: audio, destination: destination).url
        let troisieme = try await Essai(transcripteur: TranscripteurFactice(texte: "troisième texte"), fuseau: paris)
            .executer(audio: audio, destination: destination).url

        #expect(deuxieme.lastPathComponent == "2026-10-09 13h21 - Vocal - Vocal sans titre (2).md")
        #expect(troisieme.lastPathComponent == "2026-10-09 13h21 - Vocal - Vocal sans titre (3).md")
        #expect(try String(contentsOf: premiere, encoding: .utf8).contains("premier texte"))
        #expect(try String(contentsOf: deuxieme, encoding: .utf8).contains("deuxième texte"))
        #expect(try contenu(destination).count == 3)
    }

    @Test("une transcription vide est un échec, et aucune note n'est écrite")
    func transcriptionVide() async throws {
        let destination = try dossierTemporaire()
        let essai = Essai(transcripteur: TranscripteurFactice(texte: "  \n "), fuseau: paris)

        await #expect(throws: ErreurTranscription.invraisemblable(mots: 0, duree: 6)) {
            try await essai.executer(audio: fixtures.appendingPathComponent("watch.m4a"), destination: destination).url
        }
        #expect(try contenu(destination).isEmpty)
    }

    @Test("au-delà de 20 s, moins de 10 mots par minute est un échec")
    func tropPeuDeMots() async throws {
        let destination = try dossierTemporaire()
        let audio = fixtures.appendingPathComponent("silence-ipad.m4a")

        await #expect(throws: ErreurTranscription.invraisemblable(mots: 2, duree: 30)) {
            try await Essai(transcripteur: TranscripteurFactice(texte: "un deux"), fuseau: paris)
                .executer(audio: audio, destination: destination).url
        }
        #expect(try contenu(destination).isEmpty)

        let note = try await Essai(transcripteur: TranscripteurFactice(texte: "un deux trois quatre cinq six"), fuseau: paris)
            .executer(audio: audio, destination: destination).url
        #expect(note.lastPathComponent == "2026-11-01 09h00 - Vocal - Vocal sans titre.md")
        #expect(try String(contentsOf: note, encoding: .utf8).contains("\nduree: \"0:30\"\nmemo: \"Silence\"\nappareil: ipad\n"))
    }

    @Test("un mémo iPhone en .qta prend le titre inscrit dans le fichier")
    func memoIphoneQta() async throws {
        let destination = try dossierTemporaire()
        let note = try await Essai(transcripteur: TranscripteurFactice(texte: "texte"), fuseau: paris)
            .executer(audio: fixtures.appendingPathComponent("iphone.qta"), destination: destination).url

        #expect(note.lastPathComponent == "2026-07-02 19h16 - Vocal - Vocal sans titre.md")
        let texte = try String(contentsOf: note, encoding: .utf8)
        #expect(texte.contains("\nmemo: \"Rue des Essais 12\"\nappareil: iphone\n"))
        #expect(texte.contains("\ndate: 2026-07-02\n"))
    }

    @Test("guillemets et barre oblique inverse du nom du mémo sont échappés dans le frontmatter")
    func echappement() async throws {
        let destination = try dossierTemporaire()
        let note = try await Essai(transcripteur: TranscripteurFactice(texte: "texte"), fuseau: paris)
            .executer(audio: fixtures.appendingPathComponent("guillemets.m4a"), destination: destination).url

        let texte = try String(contentsOf: note, encoding: .utf8)
        #expect(texte.contains(#"memo: "Idée \"folle\" \\ à tester""#))
    }

    @Test("sans métadonnées, la date vient du nom de fichier du Dictaphone, le nom aussi, et l'appareil est omis")
    func sansMetadonnees() async throws {
        let destination = try dossierTemporaire()
        let source = try dossierTemporaire().appendingPathComponent("20260115 080000-ABCDEF12.m4a")
        try FileManager.default.copyItem(at: fixtures.appendingPathComponent("sans-meta.m4a"), to: source)
        let modification = ISO8601DateFormatter().date(from: "2026-03-20T12:00:00Z")!
        try FileManager.default.setAttributes([.modificationDate: modification], ofItemAtPath: source.path)

        let note = try await Essai(transcripteur: TranscripteurFactice(texte: "texte"), fuseau: paris)
            .executer(audio: source, destination: destination).url

        #expect(note.lastPathComponent == "2026-01-15 08h00 - Vocal - Vocal sans titre.md")
        let texte = try String(contentsOf: note, encoding: .utf8)
        #expect(texte.contains("\nmemo: \"20260115 080000-ABCDEF12\"\nllm: aucun\n"))
        #expect(!texte.contains("appareil:"))
    }

    @Test("sans métadonnées ni nom du Dictaphone, la date vient de la date de modification du fichier")
    func dateDeModification() async throws {
        let destination = try dossierTemporaire()
        let source = try dossierTemporaire().appendingPathComponent("copie quelconque.m4a")
        try FileManager.default.copyItem(at: fixtures.appendingPathComponent("sans-meta.m4a"), to: source)
        let modification = ISO8601DateFormatter().date(from: "2026-03-20T12:00:00Z")!
        try FileManager.default.setAttributes([.modificationDate: modification], ofItemAtPath: source.path)

        let note = try await Essai(transcripteur: TranscripteurFactice(texte: "texte"), fuseau: paris)
            .executer(audio: source, destination: destination).url

        #expect(note.lastPathComponent == "2026-03-20 13h00 - Vocal - Vocal sans titre.md")
    }

    @Test("un fichier qui n'est pas de l'audio est refusé sans écrire de note")
    func pasDeLAudio() async throws {
        let destination = try dossierTemporaire()
        let faux = try dossierTemporaire().appendingPathComponent("faux.m4a")
        try Data("ceci n'est pas de l'audio".utf8).write(to: faux)

        await #expect(throws: ErreurEssai.audioIllisible(faux.path)) {
            try await Essai(transcripteur: TranscripteurFactice(texte: "texte"), fuseau: paris)
                .executer(audio: faux, destination: destination).url
        }
        #expect(try contenu(destination).isEmpty)
    }

    @Test("un dossier de destination absent est refusé, sans le créer")
    func destinationAbsente() async throws {
        let absente = try dossierTemporaire().appendingPathComponent("absente", isDirectory: true)

        await #expect(throws: ErreurEssai.destinationAbsente(absente.path)) {
            try await Essai(transcripteur: TranscripteurQuiEchoue(), fuseau: paris)
                .executer(audio: fixtures.appendingPathComponent("watch.m4a"), destination: absente).url
        }
        #expect(!FileManager.default.fileExists(atPath: absente.path))
    }
}
