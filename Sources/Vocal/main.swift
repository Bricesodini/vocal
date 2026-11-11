// Vocal : mémos du Dictaphone vers notes vocales. Branche les adaptateurs réels sur le domaine.
import AppKit
import Foundation
import VocalCore
import VocalLLM
import VocalSpeech

let usage = """
usage :
  Vocal passage [--dossier <enregistrements>] [--reglages <fichier>] [--etat <dossier>]
                                                        traite les mémos prêts du Dictaphone et écrit leurs notes
                                                        dans l'inbox réglée ; utilisé par launchd
  Vocal traiter <titre ou nom de fichier> [--encore] [--dossier <enregistrements>] [--reglages <fichier>] [--etat <dossier>]
                                                        écrit dans l'inbox la note d'un mémo précis, même ancien ou
                                                        ignoré à l'amorçage ; --encore pour un mémo déjà traité
  Vocal état [--etat <dossier>]                         mémos traités, en attente, en échec, et derniers passages
  Vocal essai <fichier audio> --destination <dossier> [--reglages <fichier>]
                                                        transcrit un fichier et écrit sa note dans le dossier ;
                                                        rédige titre, résumé et texte nettoyé si un LLM est réglé
  Vocal modèle [--installer]                            affiche l'état du modèle Apple fr_FR, ou l'installe
  Vocal observer [--dossier <enregistrements>] --sortie <dossier>
                                                        rapport sans contenu personnel sur le dossier du
                                                        Dictaphone, et essai sur le dernier mémo
"""

/// Fichier de réglages par défaut, au format inspiré d'opencode.
let reglagesParDefaut = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/vocal/vocal.json")

/// Dossier d'état de Vocal (base, verrou, cache), hors du vault, et journal des passages.
let etatParDefaut = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/Vocal", isDirectory: true)
let journalParDefaut = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Vocal/vocal.log")

/// Dossier des enregistrements du Dictaphone sur le Mac.
let dossierDictaphone = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings", isDirectory: true)

enum Sortie: Int32 {
    case usage = 64, transcriptionInvraisemblable = 65, memoIntraitable = 66, modeleAbsent = 69, echec = 70,
         dejaEnCours = 75, accesRefuse = 77, reglages = 78

    /// Code de sortie d'une erreur, le même pour toutes les commandes.
    init(_ erreur: any Error) {
        switch erreur {
        case is ErreurTranscription: self = .transcriptionInvraisemblable
        case is ModeleApple.Erreur: self = .modeleAbsent
        case is ErreurReglages: self = .reglages
        case is ErreurTraiter: self = .memoIntraitable
        case ErreurPassage.dejaEnCours: self = .dejaEnCours
        case ErreurPassage.enregistrementsIllisibles: self = .accesRefuse
        case ErreurPassage.inboxAbsente: self = .reglages
        case ErreurPassage.autreDossier: self = .reglages
        default: self = .echec
        }
    }
}

func quitter(_ message: String, _ code: Sortie) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code.rawValue)
}

/// Lit les réglages. Un fichier nommé explicitement doit exister : sinon le LLM et l'inbox seraient
/// désactivés sans le dire.
func chargerReglages(_ fichier: URL, explicite: Bool) -> Reglages {
    if explicite, !FileManager.default.fileExists(atPath: fichier.path) {
        quitter("échec : fichier de réglages introuvable : \(fichier.path)", .reglages)
    }
    do { return try Reglages.charger(fichier) } catch { quitter("échec : \(error)", Sortie(error)) }
}

/// Obsidian Sync ne pousse une note que si Obsidian tourne. Après l'écriture d'une note dans la vraie inbox, Vocal le
/// lance donc s'il ne tourne pas, caché ; Obsidian rouvre les coffres ouverts à sa dernière fermeture. Obsidian prend
/// lui-même le premier plan en ouvrant sa fenêtre : Vocal le masque de nouveau pendant ses 10 premières secondes.
/// Un échec ne change rien aux notes écrites : il est seulement signalé.
func reveillerObsidian() async {
    let obsidian = "md.obsidian"
    guard NSRunningApplication.runningApplications(withBundleIdentifier: obsidian).isEmpty else { return }
    // Sans Obsidian installé, il n'y a rien à synchroniser.
    guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: obsidian) else { return }
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = false
    configuration.hides = true
    configuration.addsToRecentItems = false
    do {
        let lancee = try await NSWorkspace.shared.openApplication(at: app, configuration: configuration)
        for _ in 0..<20 {
            try? await Task.sleep(for: .milliseconds(500))
            if !lancee.isHidden { lancee.hide() }
        }
        print("obsidian : lancé caché pour la synchronisation")
    } catch {
        print("obsidian : lancement impossible (\((error as NSError).code)), la note attendra son ouverture")
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let commande = arguments.first else { quitter(usage, .usage) }

switch commande {
case "essai":
    var audio: String?
    var destination: String?
    var fichierReglages = reglagesParDefaut
    var reglagesExplicites = false
    var reste = arguments.dropFirst().makeIterator()
    while let a = reste.next() {
        switch a {
        case "--destination": destination = reste.next()
        case "--reglages":
            guard let chemin = reste.next(), !chemin.isEmpty else { quitter(usage, .usage) }
            fichierReglages = URL(fileURLWithPath: chemin)
            reglagesExplicites = true
        default: if audio == nil, !a.hasPrefix("--") { audio = a } else { quitter(usage, .usage) }
        }
    }
    guard let audio, let destination else { quitter(usage, .usage) }
    let reglages = chargerReglages(fichierReglages, explicite: reglagesExplicites)
    do {
        let redacteur = reglages.llm.map { ClientLLM($0, glossaire: reglages.glossaire) }
        let note = try await Essai(transcripteur: TranscripteurApple(), redacteur: redacteur)
            .executer(audio: URL(fileURLWithPath: audio), destination: URL(fileURLWithPath: destination, isDirectory: true))
        switch note.redaction {
        case .sansLLM: break
        case .redigee: FileHandle.standardError.write(Data("rédacteur : note rédigée par \(redacteur?.nom ?? "?")\n".utf8))
        case let .rejetee(raison): FileHandle.standardError.write(Data("rédacteur : pas de rédaction (\(raison)), note écrite avec la transcription brute seule\n".utf8))
        }
        print(note.url.path)
    } catch {
        quitter("échec : \(error)", Sortie(error))
    }

case "passage", "traiter":
    var designation: String?
    var encore = false
    var dossier = dossierDictaphone
    var fichierReglages = reglagesParDefaut
    var reglagesExplicites = false
    var etat = etatParDefaut
    var journal = journalParDefaut
    var essai = false
    var reste = arguments.dropFirst().makeIterator()
    while let a = reste.next() {
        if commande == "traiter", a == "--encore" { encore = true; continue }
        if commande == "traiter", designation == nil, !a.hasPrefix("--") { designation = a; continue }
        guard let valeur = reste.next(), !valeur.isEmpty else { quitter(usage, .usage) }
        switch a {
        case "--dossier": dossier = URL(fileURLWithPath: valeur, isDirectory: true)
        case "--reglages": fichierReglages = URL(fileURLWithPath: valeur); reglagesExplicites = true
        // Un dossier d'état d'essai garde aussi son journal : rien ne se mélange avec le vrai état.
        case "--etat":
            etat = URL(fileURLWithPath: valeur, isDirectory: true); journal = etat.appendingPathComponent("vocal.log"); essai = true
        default: quitter(usage, .usage)
        }
    }
    if commande == "traiter", designation?.isEmpty ?? true { quitter(usage, .usage) }
    let reglages = chargerReglages(fichierReglages, explicite: reglagesExplicites)
    guard let inbox = reglages.inbox else {
        quitter("aucune inbox réglée : ajouter « inbox » dans \(fichierReglages.path). Aucune note écrite.", .reglages)
    }
    let redacteur = reglages.llm.map { ClientLLM($0, glossaire: reglages.glossaire) }
    let passage = Passage(transcripteur: TranscripteurApple(modele: ModeleApple(langue: reglages.locale)), redacteur: redacteur)
    let lieux = Emplacements(enregistrements: dossier, inbox: inbox, etat: etat, journal: journal)
    do {
        if let designation {
            let note = try await passage.traiter(designation, encore: encore, lieux)
            if case let .rejetee(raison) = note.redaction {
                FileHandle.standardError.write(Data("rédacteur : pas de rédaction (\(raison)), note écrite avec la transcription brute seule\n".utf8))
            }
            print(note.url.path)
            // Un état d'essai (--etat) n'écrit pas dans le vrai coffre : Obsidian n'a pas à être lancé.
            if !essai { await reveillerObsidian() }
        } else {
            let bilan = try await passage.executer(lieux)
            print(bilan.amorcage.map { "amorçage : \($0) mémo(s) déjà présent(s) marqué(s) ignoré(s), aucune note écrite" }
                  ?? "passage : \(bilan.notes.count) note(s) écrite(s), \(bilan.enAttente) en attente, \(bilan.echecs) échec(s)")
            if !essai, !bilan.notes.isEmpty { await reveillerObsidian() }
        }
    } catch ErreurPassage.enregistrementsIllisibles {
        quitter("échec : lecture du dossier des enregistrements refusée ou impossible. Si c'est le dossier du Dictaphone, "
                + "accorder l'Accès complet au disque à ~/Applications/Vocal.app et lancer Vocal depuis cette app.", .accesRefuse)
    } catch {
        quitter("échec : \(error)", Sortie(error))
    }

case "état", "etat":
    var etat = etatParDefaut
    var reste = arguments.dropFirst().makeIterator()
    while let a = reste.next() {
        guard a == "--etat", let valeur = reste.next(), !valeur.isEmpty else { quitter(usage, .usage) }
        etat = URL(fileURLWithPath: valeur, isDirectory: true)
    }
    do { print(try RapportEtat.texte(etat), terminator: "") } catch { quitter("échec : \(error)", Sortie(error)) }

case "modèle", "modele":
    let options = Array(arguments.dropFirst())
    guard options.isEmpty || options == ["--installer"] else { quitter(usage, .usage) }
    let modele = ModeleApple()
    do {
        if options == ["--installer"] { try await modele.installer() }
        print("modèle \(modele.langue) : \(try await modele.etat().rawValue)")
    } catch {
        quitter("échec : \(error)", Sortie(error))
    }

case "observer":
    var dossier = dossierDictaphone
    var sortie: URL?
    var reste = arguments.dropFirst().makeIterator()
    while let a = reste.next() {
        switch a {
        case "--dossier": dossier = URL(fileURLWithPath: reste.next() ?? "", isDirectory: true)
        case "--sortie": sortie = reste.next().map { URL(fileURLWithPath: $0, isDirectory: true) }
        default: quitter(usage, .usage)
        }
    }
    guard let sortie else { quitter(usage, .usage) }
    let essais = sortie.appendingPathComponent("essai", isDirectory: true)
    try? FileManager.default.createDirectory(at: essais, withIntermediateDirectories: true)

    var lignes = [
        "observation Vocal du \(ISO8601DateFormatter().string(from: Date()))",
        "exécutable : \(Bundle.main.executablePath ?? "?")",
        "bundle : \(Bundle.main.bundleIdentifier ?? "aucun")",
        "processus parent : \(getppid() == 1 ? "launchd" : "autre (pid \(getppid()))")",
        "autorisation Reconnaissance vocale : \(ModeleApple.autorisationReconnaissance())",
        "modèle fr_FR : \((try? await ModeleApple().etat().rawValue) ?? "erreur")",
    ]
    lignes += await Inventaire.dresser(dossier).texte.split(separator: "\n").map(String.init)
    if let memo = Inventaire.dernierMemo(dossier) {
        // Horodatages seulement : heure d'enregistrement, et heure d'arrivée du fichier sur le Mac.
        let iso = ISO8601DateFormatter()
        let arrivee = (try? memo.resourceValues(forKeys: [.creationDateKey]))?.creationDate
        if let infos = try? await Memo.lire(memo, fuseau: .current) {
            let delai = arrivee.map { String(format: "%.0f s", $0.timeIntervalSince(infos.dateEnregistrement)) } ?? "?"
            lignes.append("dernier mémo : enregistré \(iso.string(from: infos.dateEnregistrement)), arrivé sur le Mac "
                          + "\(arrivee.map(iso.string(from:)) ?? "?"), écart \(delai), appareil \(infos.appareil?.rawValue ?? "inconnu")")
        }
        do {
            let note = try await Essai(transcripteur: TranscripteurApple()).executer(audio: memo, destination: essais).url
            let mots = (try? String(contentsOf: note, encoding: .utf8))?
                .components(separatedBy: "## Transcription brute").last?
                .split(whereSeparator: \.isWhitespace).count ?? 0
            lignes.append("essai sur le dernier mémo : note écrite, \(mots) mots")
        } catch {
            // Jamais de chemin dans le rapport : seulement la nature de l'échec.
            let nature: String
            switch error {
            case let e as ModeleApple.Erreur: nature = e.description
            case let e as ErreurTranscription: nature = e.description
            case ErreurEssai.audioIllisible: nature = "fichier audio illisible"
            case ErreurEssai.destinationAbsente: nature = "dossier d'essai absent"
            default: nature = "\(type(of: error)) \((error as NSError).domain) \((error as NSError).code)"
            }
            lignes.append("essai sur le dernier mémo : échec, \(nature)")
        }
    } else {
        lignes.append("essai sur le dernier mémo : aucun mémo lisible")
    }
    let rapport = sortie.appendingPathComponent("observation-\(Int(Date().timeIntervalSince1970)).txt")
    do {
        try (lignes.joined(separator: "\n") + "\n").write(to: rapport, atomically: true, encoding: .utf8)
        print(rapport.path)
    } catch {
        quitter("échec : \(error)", .echec)
    }

default:
    quitter(usage, .usage)
}
