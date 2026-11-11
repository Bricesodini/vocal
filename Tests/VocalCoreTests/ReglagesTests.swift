import Foundation
import Testing
import VocalCore

@Suite("Réglages")
struct ReglagesTests {
    func fichier(_ json: String) throws -> URL {
        let url = try dossierTemporaire().appendingPathComponent("vocal.json")
        try json.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test("sans fichier, aucun LLM n'est réglé, ni inbox, ni glossaire")
    func sansFichier() throws {
        let reglages = try Reglages.charger(try dossierTemporaire().appendingPathComponent("absent.json"))
        #expect(reglages.llm == nil)
        #expect(reglages.inbox == nil)
        #expect(reglages.glossaire.isEmpty)
        #expect(reglages.locale == "fr_FR")
    }

    @Test("un fichier complet donne le modèle, son fournisseur et le glossaire")
    func fichierComplet() throws {
        let reglages = try Reglages.charger(try fichier("""
        {
          "inbox": "/tmp/inbox test",
          "locale": "fr_CA",
          "model": "maison/mistral-small",
          "providers": {
            "maison": {
              "protocol": "openai-compatible",
              "baseURL": "http://127.0.0.1:1234/v1",
              "apiKey": "keychain:vocal-maison",
              "timeoutSeconds": 30
            },
            "nuage": { "protocol": "anthropic", "apiKey": "keychain:vocal-nuage" }
          },
          "glossary": ["SaaS", "SEO", "MJC"]
        }
        """))
        #expect(reglages.inbox?.path == "/tmp/inbox test")
        #expect(reglages.locale == "fr_CA")
        #expect(reglages.glossaire == ["SaaS", "SEO", "MJC"])
        let llm = try #require(reglages.llm)
        #expect(llm.nom == "maison/mistral-small")
        #expect(llm.modele == "mistral-small")
        #expect(llm.protocole == .openaiCompatible)
        #expect(llm.adresse.absoluteString == "http://127.0.0.1:1234/v1")
        #expect(llm.cleTrousseau == "vocal-maison")
        #expect(llm.delai == 30)
    }

    @Test("le protocole anthropic a une adresse et un délai par défaut")
    func anthropicParDefaut() throws {
        let reglages = try Reglages.charger(try fichier("""
        {"model": "nuage/claude-haiku-5-5",
         "providers": {"nuage": {"protocol": "anthropic", "apiKey": "keychain:vocal-nuage"}}}
        """))
        let llm = try #require(reglages.llm)
        #expect(llm.adresse.absoluteString == "https://api.anthropic.com/v1")
        #expect(llm.delai == 120)
    }

    @Test("le nom du modèle peut lui-même contenir une barre oblique")
    func modeleAvecBarre() throws {
        let reglages = try Reglages.charger(try fichier("""
        {"model": "routeur/mistralai/mistral-small",
         "providers": {"routeur": {"protocol": "openai-compatible", "baseURL": "http://localhost:8080/v1"}}}
        """))
        let llm = try #require(reglages.llm)
        #expect(llm.modele == "mistralai/mistral-small")
        #expect(llm.cleTrousseau == nil)
    }

    @Test("une clé en clair fait refuser le fichier, sans que la clé apparaisse dans l'erreur")
    func cleEnClair() throws {
        let url = try fichier("""
        {"model": "nuage/m", "providers": {"nuage": {"protocol": "anthropic", "apiKey": "sk-secret-123"}}}
        """)
        #expect(throws: ErreurReglages.cleEnClair(fournisseur: "nuage")) { try Reglages.charger(url) }
        do { _ = try Reglages.charger(url) } catch { #expect(!"\(error)".contains("sk-secret-123")) }
    }

    @Test("une clé en clair est refusée même chez un fournisseur non choisi")
    func cleEnClairAilleurs() throws {
        let url = try fichier("""
        {"model": "", "providers": {"autre": {"protocol": "anthropic", "apiKey": "sk-secret-123"}}}
        """)
        #expect(throws: ErreurReglages.cleEnClair(fournisseur: "autre")) { try Reglages.charger(url) }
    }

    @Test("une clé rangée ailleurs que dans apiKey (options.apiKey d'opencode) fait refuser le fichier, sans la reprendre")
    func cleAilleurs() throws {
        let url = try fichier("""
        {"model": "nuage/m", "providers": {"nuage": {"protocol": "anthropic", "options": {"apiKey": "sk-secret-123"}}}}
        """)
        #expect(throws: ErreurReglages.champInconnu(fournisseur: "nuage", champ: "options")) { try Reglages.charger(url) }
        do { _ = try Reglages.charger(url) } catch { #expect(!"\(error)".contains("sk-secret-123")) }
    }

    @Test("un modèle mal formé n'est pas recopié dans l'erreur")
    func modeleNonRecopie() throws {
        let url = try fichier(#"{"model": "sk-secret-123"}"#)
        do { _ = try Reglages.charger(url) } catch { #expect(!"\(error)".contains("sk-secret-123")) }
    }

    @Test("un modèle vide ou absent : aucun LLM, même avec des fournisseurs")
    func modeleVide() throws {
        let json = """
        {"providers": {"maison": {"protocol": "openai-compatible", "baseURL": "http://localhost:1/v1"}}}
        """
        #expect(try Reglages.charger(try fichier(json)).llm == nil)
        #expect(try Reglages.charger(try fichier(#"{"model": "  "}"#)).llm == nil)
    }

    @Test("un modèle sans fournisseur connu, ou mal formé, fait refuser le fichier")
    func fournisseurInconnu() throws {
        #expect(throws: ErreurReglages.fournisseurInconnu("ailleurs")) {
            try Reglages.charger(try fichier(#"{"model": "ailleurs/m", "providers": {}}"#))
        }
        #expect(throws: ErreurReglages.modeleMalForme) {
            try Reglages.charger(try fichier(#"{"model": "sansbarre"}"#))
        }
    }

    @Test("un protocole inconnu ou une adresse manquante fait refuser le fichier")
    func fournisseurIncomplet() throws {
        #expect(throws: ErreurReglages.protocoleInconnu(fournisseur: "x")) {
            try Reglages.charger(try fichier(#"{"providers": {"x": {"protocol": "grpc", "baseURL": "http://a/v1"}}}"#))
        }
        #expect(throws: ErreurReglages.adresseManquante(fournisseur: "x")) {
            try Reglages.charger(try fichier(#"{"providers": {"x": {"protocol": "openai-compatible"}}}"#))
        }
    }

    @Test("un fichier qui n'est pas du JSON valide est refusé")
    func jsonInvalide() throws {
        #expect(throws: ErreurReglages.self) { try Reglages.charger(try fichier("{ pas du json")) }
    }
}
