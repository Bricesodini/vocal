import Foundation
import Testing
import VocalCore

/// Rédacteur factice : rend une rédaction fixée, ou échoue. Il garde ce qu'il a reçu.
final class RedacteurFactice: Redacteur, @unchecked Sendable {
    let nom = "maison/modele-test"
    var reponse: Result<Redaction, any Error>
    private(set) var recu: [String] = []
    init(_ reponse: Result<Redaction, any Error>) { self.reponse = reponse }
    func rediger(_ transcription: String) async throws -> Redaction {
        recu.append(transcription)
        return try reponse.get()
    }
}

struct PanneLLM: Error {}

@Suite("Commande essai avec rédacteur")
struct RedacteurTests {
    let brut = "euh bonjour alors on on se voit jeudi non plutôt vendredi pour le SIO merci"
    let watch = fixtures.appendingPathComponent("watch.m4a")

    func essai(_ redacteur: RedacteurFactice?) -> Essai {
        Essai(transcripteur: TranscripteurFactice(texte: brut), redacteur: redacteur, fuseau: paris)
    }

    @Test("une réponse valide donne le titre, le résumé et le texte nettoyé au-dessus du brut intact")
    func gabaritComplet() async throws {
        let destination = try dossierTemporaire()
        let redacteur = RedacteurFactice(.success(Redaction(
            titre: "Rendez-vous SEO vendredi",
            resume: "Un rendez-vous est fixé à vendredi pour parler SEO.",
            texte: "Bonjour, on se voit vendredi pour le SEO.")))

        let ecrite = try await essai(redacteur).executer(audio: watch, destination: destination)

        #expect(ecrite.url.lastPathComponent == "2026-10-09 13h21 - Vocal - Rendez-vous SEO vendredi.md")
        #expect(ecrite.redaction == .redigee)
        #expect(redacteur.recu == [brut])
        #expect(try String(contentsOf: ecrite.url, encoding: .utf8) == """
        ---
        type: note-vocale
        date: 2026-10-09
        source: vocal
        statut: à traiter
        duree: "0:06"
        memo: "watch"
        appareil: watch
        llm: "maison/modele-test"
        ---

        # Rendez-vous SEO vendredi

        ## Résumé

        Un rendez-vous est fixé à vendredi pour parler SEO.

        ## Texte nettoyé

        Bonjour, on se voit vendredi pour le SEO.

        ## Transcription brute

        \(brut)

        """)
    }

    @Test("le frontmatter est le même avec ou sans rédacteur, sauf le champ llm")
    func frontmatterIdentique() async throws {
        let destination = try dossierTemporaire()
        let avec = try await essai(RedacteurFactice(.success(Redaction(titre: "Titre", resume: "R.", texte: brut))))
            .executer(audio: watch, destination: destination).url
        let sans = try await essai(nil).executer(audio: watch, destination: destination).url

        func frontmatter(_ url: URL) throws -> [String] {
            let lignes = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
            return Array(lignes[1..<lignes[1...].firstIndex(of: "---")!]).filter { !$0.hasPrefix("llm:") }
        }
        #expect(try frontmatter(avec) == frontmatter(sans))
    }

    @Test("sans rédacteur, la note ne contient que la transcription brute, et l'issue le dit")
    func sansRedacteur() async throws {
        let ecrite = try await essai(nil).executer(audio: watch, destination: try dossierTemporaire())
        #expect(ecrite.redaction == .sansLLM)
        let texte = try String(contentsOf: ecrite.url, encoding: .utf8)
        #expect(texte.contains("llm: aucun"))
        #expect(!texte.contains("## Résumé"))
        #expect(!texte.contains("## Texte nettoyé"))
    }

    @Test("une erreur quelconque du rédacteur ne donne que son type, jamais sa description")
    func erreurQuelconque() async throws {
        let bavarde = NSError(domain: "x", code: 1, userInfo: [NSLocalizedDescriptionKey: "contenu-prive du mémo"])
        let ecrite = try await essai(RedacteurFactice(.failure(bavarde)))
            .executer(audio: watch, destination: try dossierTemporaire())
        #expect(ecrite.redaction == .rejetee("NSError"))
    }

    @Test("un rédacteur en échec : note écrite avec le titre de repli, sans résumé ni texte nettoyé")
    func redacteurEnEchec() async throws {
        let ecrite = try await essai(RedacteurFactice(.failure(PanneLLM())))
            .executer(audio: watch, destination: try dossierTemporaire())
        #expect(ecrite.url.lastPathComponent == "2026-10-09 13h21 - Vocal - Vocal sans titre.md")
        #expect(ecrite.redaction == .rejetee("PanneLLM"))
        let texte = try String(contentsOf: ecrite.url, encoding: .utf8)
        #expect(texte.contains("llm: aucun"))
        #expect(!texte.contains("## Résumé"))
        #expect(!texte.contains("## Texte nettoyé"))
        #expect(texte.contains(brut))
    }

    /// Le brut compte 15 mots : 50 % = 7,5 et 120 % = 18.
    @Test("un texte nettoyé hors de 50 % à 120 % des mots du brut, ou un titre vide, est rejeté",
          arguments: [
            (Redaction(titre: "T", resume: "R", texte: "un deux trois quatre cinq six sept"), "texte nettoyé à 7 mots pour 15"),
            (Redaction(titre: "T", resume: "R", texte: Array(repeating: "mot", count: 19).joined(separator: " ")), "texte nettoyé à 19 mots pour 15"),
            (Redaction(titre: "  ", resume: "R", texte: "bonjour on se voit vendredi pour le SEO tout à fait ok"), "titre vide"),
            (Redaction(titre: "///", resume: "R", texte: "bonjour on se voit vendredi pour le SEO tout à fait ok"), "titre vide"),
          ])
    func reponseInvalide(redaction: Redaction, raison: String) async throws {
        let ecrite = try await essai(RedacteurFactice(.success(redaction)))
            .executer(audio: watch, destination: try dossierTemporaire())
        #expect(ecrite.redaction == .rejetee(raison))
        #expect(ecrite.url.lastPathComponent.hasSuffix("Vocal sans titre.md"))
        #expect(try String(contentsOf: ecrite.url, encoding: .utf8).contains("llm: aucun"))
    }

    @Test("les bornes de 8 et 18 mots sont acceptées")
    func bornes() async throws {
        for n in [8, 18] {
            let texte = Array(repeating: "mot", count: n).joined(separator: " ")
            let ecrite = try await essai(RedacteurFactice(.success(Redaction(titre: "T", resume: "R", texte: texte))))
                .executer(audio: watch, destination: try dossierTemporaire())
            #expect(ecrite.redaction == .redigee, "\(n) mots")
        }
    }

    @Test("le titre est nettoyé des caractères interdits et limité en longueur, dans le nom et l'en-tête")
    func titreNettoye() async throws {
        let destination = try dossierTemporaire()
        let titre = "  .Plan: SEO/GEO [v2] #projet | \"MJC\" ?\n" + String(repeating: "très ", count: 30)
        let ecrite = try await essai(RedacteurFactice(.success(Redaction(titre: titre, resume: "R", texte: brut))))
            .executer(audio: watch, destination: destination)
        let nom = ecrite.url.deletingPathExtension().lastPathComponent
        let titreNote = String(nom.dropFirst("2026-10-09 13h21 - Vocal - ".count))
        #expect(titreNote.hasPrefix("Plan SEO GEO v2 projet MJC très très"))
        #expect(titreNote.count <= 80)
        #expect(!titreNote.hasSuffix(" "))
        #expect(try String(contentsOf: ecrite.url, encoding: .utf8).contains("\n# \(titreNote)\n"))
    }
}
