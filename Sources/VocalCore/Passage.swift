import Darwin
import Foundation

public enum ErreurPassage: Error, Equatable, CustomStringConvertible {
    case inboxAbsente(String)
    case dejaEnCours
    case verrouImpossible
    case enregistrementsIllisibles(String)
    case autreDossier

    public var description: String {
        switch self {
        case let .inboxAbsente(chemin): return "le dossier de l'inbox n'existe pas : \(chemin)"
        case .dejaEnCours: return "un passage est déjà en cours"
        case .verrouImpossible: return "verrou du passage impossible à poser"
        case let .enregistrementsIllisibles(chemin): return "dossier des enregistrements illisible : \(chemin)"
        case .autreDossier:
            return "cet état a été amorcé sur un autre dossier des enregistrements : pour un essai, donner un dossier d'état à part (--etat)"
        }
    }
}

public enum ErreurTraiter: Error, Equatable, CustomStringConvertible {
    case pasAmorce
    case introuvable(String)
    case plusieurs([String])
    case supprime(String)
    case pasTelecharge(String)
    case dejaTraite(String)

    public var description: String {
        switch self {
        case .pasAmorce:
            return "aucun passage n'a encore eu lieu : lancer d'abord « Vocal passage », qui marque les mémos déjà présents"
        case let .introuvable(designation):
            return "aucun mémo n'a ce nom de fichier ni ce titre dans le Dictaphone : « \(designation) »"
        case let .plusieurs(fichiers):
            return "plusieurs mémos portent ce titre : désigner l'un d'eux par son nom de fichier\n"
                + fichiers.map { "  \($0)" }.joined(separator: "\n")
        case let .supprime(fichier):
            return "le mémo \(fichier) est dans « Supprimés récemment » : le récupérer d'abord dans le Dictaphone"
        case let .pasTelecharge(fichier):
            return "l'audio du mémo \(fichier) n'est pas encore téléchargé par iCloud : réessayer plus tard"
        case let .dejaTraite(fichier):
            return "le mémo \(fichier) est déjà traité : ajouter --encore pour écrire une nouvelle note"
        }
    }
}

/// Le mémo désigné à `traiter` : d'abord par son nom de fichier, avec ou sans extension ni dossier, puis par
/// son titre dans la base du Dictaphone, sans tenir compte des majuscules ni des accents.
func designer(_ designation: String, parmi releve: Releve, fiches: [String: FicheDictaphone]) throws -> FichierObserve {
    let nom = (designation as NSString).lastPathComponent
    let parNom = releve.fichiers.filter { $0.nom == nom || ($0.nom as NSString).deletingPathExtension == nom }
    let fichiersVises: [String]
    if !parNom.isEmpty {
        fichiersVises = parNom.map(\.nom)
    } else {
        let cherche = designation.trimmingCharacters(in: .whitespacesAndNewlines)
        fichiersVises = fiches.filter {
            $0.value.titre?.compare(cherche, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }.keys.sorted()
    }
    let actifs = fichiersVises.filter { fiches[$0]?.supprime != true }
    guard let vise = actifs.first else {
        if let supprime = fichiersVises.first { throw ErreurTraiter.supprime(supprime) }
        throw ErreurTraiter.introuvable(designation)
    }
    guard actifs.count == 1 else { throw ErreurTraiter.plusieurs(actifs) }
    // Une fiche sans fichier, ou un remplacement iCloud : l'audio n'est pas encore sur le Mac.
    guard let fichier = releve.fichiers.first(where: { $0.nom == vise }), !fichier.estRemplacement else {
        throw ErreurTraiter.pasTelecharge(vise)
    }
    return fichier
}

/// Où un passage lit et écrit. Vocal n'écrit que dans l'inbox, dans son dossier d'état et dans son journal.
public struct Emplacements: Sendable {
    /// Dossier du Dictaphone : lu, jamais modifié.
    public let enregistrements: URL
    /// Dossier où les notes sont écrites. Il doit exister : Vocal ne le crée jamais.
    public let inbox: URL
    /// Dossier de Vocal : base d'état, verrou et cache.
    public let etat: URL
    /// Fichier du journal.
    public let journal: URL

    public init(enregistrements: URL, inbox: URL, etat: URL, journal: URL) {
        self.enregistrements = enregistrements
        self.inbox = inbox
        self.etat = etat
        self.journal = journal
    }
}

/// Ce qu'a fait un passage.
public struct BilanPassage: Sendable {
    /// Mémos marqués `ignoré` si ce passage est l'amorçage, nil sinon.
    public var amorcage: Int?
    /// Notes écrites, y compris les notes « transcription impossible ».
    public var notes: [NoteEcrite] = []
    /// Mémos présents encore `vu` : en observation, ou en échec de transcription à réessayer.
    public var enAttente = 0
    /// Mémos passés en `échec` à ce passage.
    public var echecs = 0
}

/// Commande `passage` : repère les mémos prêts du dossier des enregistrements et écrit leurs notes dans l'inbox.
public struct Passage: Sendable {
    static let delaiDeStabilite: TimeInterval = 12
    static let tentativesMaximum = 3

    let transcripteur: any Transcripteur
    let redacteur: (any Redacteur)?
    let horloge: any Horloge
    let fuseau: TimeZone

    public init(transcripteur: any Transcripteur, redacteur: (any Redacteur)? = nil,
                horloge: any Horloge = HorlogeSysteme(), fuseau: TimeZone = .current) {
        self.transcripteur = transcripteur
        self.redacteur = redacteur
        self.horloge = horloge
        self.fuseau = fuseau
    }

    /// Une erreur d'écriture dans l'inbox ou dans l'état arrête le passage sans compter de tentative :
    /// elle n'est la faute d'aucun mémo, et le passage suivant reprendra.
    public func executer(_ lieux: Emplacements) async throws -> BilanPassage {
        let seance = try ouvrir(lieux)
        defer { seance.verrou.liberer() }
        let (base, journal, cache) = (seance.base, seance.journal, seance.cache)
        let debut = horloge.maintenant().timeIntervalSince1970
        var bilan = BilanPassage()

        if try base.nombreDePassages() == 0 {
            let presents = try Releve.memos(lieux.enregistrements, avecRemplacements: true).fichiers
            try base.transaction {
                for f in presents { try base.inserer(f, statut: .ignore, maintenant: debut) }
                try base.fixerDossierAmorce(seance.dossier)
                bilan.amorcage = presents.count
                try base.noterPassage(debut: debut, fin: debut, bilan)
            }
            journal.ecrire("amorçage : \(presents.count) mémo(s) présent(s) marqué(s) ignoré(s)")
            return bilan
        }
        try verifierDossier(seance)
        try reprendreEcritures(base, inbox: lieux.inbox, journal: journal)
        let fiches = lireCatalogue(lieux.enregistrements, cache: cache, journal: journal)

        // Un mémo dans « Supprimés récemment » compte comme absent : il n'est pas traité, et il redevient
        // un mémo nouveau s'il est récupéré.
        func releve() throws -> Releve { try Releve.memos(lieux.enregistrements).sans { fiches[$0]?.supprime == true } }
        var suivi = Suivi(base: base, memos: try base.memos(), horloge: horloge)
        try suivi.observer(try releve())
        // Un même passage peut faire les deux observations : on attend ce qu'il faut, 12 s au plus.
        if let attente = suivi.attenteRestante(), attente > 0 {
            await horloge.attendre(attente)
            try suivi.observer(try releve())
        }

        let traitement = Traitement(transcripteur: transcripteur, redacteur: redacteur, fuseau: fuseau)
        if !suivi.prets.isEmpty { try await transcripteur.preparer() }
        for fichier in suivi.prets {
            guard var ligne = suivi.memos[fichier.nom] else { continue }
            let id = identite(ligne)
            let debutTranscription = ContinuousClock.now
            var memoLu: Memo?
            let resultat: Result<(Memo, String), any Error>
            do {
                resultat = .success(try await transcrire(fichier, titre: fiches[fichier.nom]?.titre, traitement, cache: cache, memoLu: &memoLu))
            } catch {
                // Un audio disparu n'est pas un échec : le mémo sera oublié, ou repris s'il revient.
                guard FileManager.default.fileExists(atPath: fichier.url.path) else {
                    journal.ecrire("mémo \(id) : audio absent, aucune tentative comptée")
                    continue
                }
                resultat = .failure(error)
            }
            let dureeTranscription = ContinuousClock.now - debutTranscription

            switch resultat {
            case let .success((memo, texte)):
                let redigee = await traitement.note(memo, transcription: texte)
                let url = try publier(redigee.note, &ligne, statut: .traite, base: base, inbox: lieux.inbox)
                bilan.notes.append(NoteEcrite(url: url, redaction: redigee.issue))
                journal.ecrire("mémo \(id) : traité " + bilanDeTraitement(memo, dureeTranscription, redigee))
            case let .failure(erreur):
                ligne.tentatives += 1
                // Aucune parole : un appui involontaire, ou un audio pris avant d'être complet. Réessayé comme un
                // échec, il est ensuite écarté sans note, car il n'a rien à transmettre.
                let sansParole = if case ErreurTranscription.invraisemblable(mots: 0, _) = erreur { true } else { false }
                let echec = sansParole
                    ? "mémo \(id) : aucune parole détectée \(ligne.tentatives)/\(Self.tentativesMaximum)"
                    : "mémo \(id) : échec de transcription \(ligne.tentatives)/\(Self.tentativesMaximum) (\(nature(erreur)))"
                if ligne.tentatives >= Self.tentativesMaximum, sansParole {
                    ligne.statut = .sansParole
                    try base.enregistrer(ligne, maintenant: horloge.maintenant().timeIntervalSince1970)
                    journal.ecrire(echec + ", mémo écarté sans note")
                } else if ligne.tentatives < Self.tentativesMaximum {
                    try base.enregistrer(ligne, maintenant: horloge.maintenant().timeIntervalSince1970)
                    journal.ecrire(echec + ", réessai au prochain passage")
                } else {
                    let memo = memoLu ?? Memo.deSecours(fichier.url, fuseau: fuseau, repli: horloge.maintenant())
                        .nomme(fiches[fichier.nom]?.titre)
                    let url = try publier(NoteVocale(transcriptionImpossible: memo), &ligne, statut: .echec, base: base, inbox: lieux.inbox)
                    bilan.notes.append(NoteEcrite(url: url, redaction: .sansLLM))
                    bilan.echecs += 1
                    journal.ecrire(echec + ", note « transcription impossible » écrite")
                }
            }
            suivi.memos[fichier.nom] = ligne
        }

        bilan.enAttente = suivi.enAttente
        try base.noterPassage(debut: debut, fin: horloge.maintenant().timeIntervalSince1970, bilan)
        journal.ecrire("passage : \(bilan.notes.count) note(s) écrite(s), \(bilan.enAttente) mémo(s) en attente, \(bilan.echecs) échec(s)")
        return bilan
    }

    /// Commande `traiter` : écrit la note d'un mémo désigné par son nom de fichier ou par son titre dans le Dictaphone,
    /// même ancien ou ignoré à l'amorçage, sans attendre sa stabilité. Un mémo déjà traité ne l'est de nouveau qu'avec
    /// `encore`. Un échec ne compte pas de tentative et ne change pas l'état.
    public func traiter(_ designation: String, encore: Bool = false, _ lieux: Emplacements) async throws -> NoteEcrite {
        let seance = try ouvrir(lieux)
        defer { seance.verrou.liberer() }
        let (base, journal, cache) = (seance.base, seance.journal, seance.cache)
        guard try base.nombreDePassages() > 0 else { throw ErreurTraiter.pasAmorce }
        try verifierDossier(seance)
        let fiches = lireCatalogue(lieux.enregistrements, cache: cache, journal: journal)
        let fichier = try designer(designation, parmi: try Releve.memos(lieux.enregistrements, avecRemplacements: true), fiches: fiches)
        // Le mémo est bien désigné : les écritures interrompues peuvent être terminées avant de lire son statut.
        try reprendreEcritures(base, inbox: lieux.inbox, journal: journal)
        let connue = try base.memos()[fichier.nom]
        if let connue, connue.statut == .traite, !encore { throw ErreurTraiter.dejaTraite(fichier.nom) }

        try await transcripteur.preparer()
        let traitement = Traitement(transcripteur: transcripteur, redacteur: redacteur, fuseau: fuseau)
        let debutTranscription = ContinuousClock.now
        var memoLu: Memo?
        let (memo, texte) = try await transcrire(fichier, titre: fiches[fichier.nom]?.titre, traitement, cache: cache, memoLu: &memoLu)
        let dureeTranscription = ContinuousClock.now - debutTranscription
        let redigee = await traitement.note(memo, transcription: texte)
        var ligne = try connue ?? base.inserer(fichier, statut: .vu, maintenant: horloge.maintenant().timeIntervalSince1970)
        let url = try publier(redigee.note, &ligne, statut: .traite, base: base, inbox: lieux.inbox)
        journal.ecrire("mémo \(identite(ligne)) : traité à la demande " + bilanDeTraitement(memo, dureeTranscription, redigee))
        return NoteEcrite(url: url, redaction: redigee.issue)
    }

    /// Ce qu'ouvrent `passage` et `traiter` : l'inbox est vérifiée, le verrou posé, l'état ouvert et le cache vidé.
    private struct Seance {
        let verrou: Verrou
        let base: BaseEtat
        let journal: Journal
        let cache: URL
        /// Chemin normalisé du dossier des enregistrements, comparé à celui de l'amorçage.
        let dossier: String
    }

    private func ouvrir(_ lieux: Emplacements) throws -> Seance {
        guard estDossier(lieux.inbox) else { throw ErreurPassage.inboxAbsente(lieux.inbox.path) }
        try FileManager.default.createDirectory(at: lieux.etat, withIntermediateDirectories: true)
        let verrou = try Verrou(lieux.etat.appendingPathComponent("verrou"))
        do {
            let base = try BaseEtat(lieux.etat)
            // Sous verrou, tout ce qui reste dans le cache vient d'un traitement interrompu.
            let cache = lieux.etat.appendingPathComponent("cache", isDirectory: true)
            try? FileManager.default.removeItem(at: cache)
            return Seance(verrou: verrou, base: base, journal: Journal(lieux.journal, horloge: horloge), cache: cache,
                          dossier: lieux.enregistrements.standardizedFileURL.path)
        } catch {
            verrou.liberer()
            throw error
        }
    }

    /// Sur un état déjà amorcé : refuse un autre dossier des enregistrements que celui de l'amorçage.
    private func verifierDossier(_ seance: Seance) throws {
        if let amorce = try seance.base.dossierAmorce() {
            guard amorce == seance.dossier else { throw ErreurPassage.autreDossier }
        } else {
            try seance.base.fixerDossierAmorce(seance.dossier)
        }
    }

    /// Copie l'audio dans le cache, lit ses métadonnées sous le titre de la base du Dictaphone, et le transcrit.
    /// `memoLu` garde les métadonnées lues même si la transcription échoue ensuite.
    private func transcrire(_ fichier: FichierObserve, titre: String?, _ traitement: Traitement, cache: URL,
                            memoLu: inout Memo?) async throws -> (Memo, String) {
        let copie = try copierEnCache(fichier.url, dans: cache)
        defer { try? FileManager.default.removeItem(at: copie.deletingLastPathComponent()) }
        let memo: Memo
        do { memo = try await Memo.lire(copie, fuseau: fuseau).nomme(titre) } catch { throw AudioIllisible() }
        memoLu = memo
        return (memo, try await traitement.transcrire(copie, memo: memo))
    }

    /// Fin de la ligne de journal d'un mémo traité : durées et modèle, jamais de texte.
    private func bilanDeTraitement(_ memo: Memo, _ transcription: Duration, _ redigee: (note: NoteVocale, issue: IssueRedaction, duree: Duration)) -> String {
        "(audio \(NoteVocale.duree(memo.duree)), transcription \(secondes(transcription)), "
            + "rédaction \(redigee.issue.libelle) en \(secondes(redigee.duree)), llm \(redigee.note.llm ?? "aucun"))"
    }

    /// Fiches de la base du Dictaphone. Une base absente, illisible ou au schéma différent ne fait jamais échouer :
    /// le passage continue sans elle, et le journal le dit.
    private func lireCatalogue(_ enregistrements: URL, cache: URL, journal: Journal) -> [String: FicheDictaphone] {
        let lecture = CatalogueDictaphone.lire(enregistrements, copies: cache)
        if case let .ecart(raison) = lecture { journal.ecrire("base du Dictaphone \(raison) : noms des mémos et suppressions inconnus") }
        return lecture.fiches
    }

    /// Écrit la note d'un mémo et le fait passer au statut visé. L'état note l'écriture en cours entre le fichier
    /// temporaire et son renommage : après une coupure, `reprendreEcritures` la termine au lieu d'écrire une deuxième note.
    private func publier(_ note: NoteVocale, _ ligne: inout LigneMemo, statut: Statut, base: BaseEtat, inbox: URL) throws -> URL {
        let nomDeBase = note.nomDeBase(fuseau: fuseau)
        let temporaire = try EcritureNote.preparer(note.texte(fuseau: fuseau), dans: inbox)
        ligne.ecriture = .init(temporaire: temporaire.lastPathComponent, nomDeBase: nomDeBase, statut: statut)
        do { try base.enregistrer(ligne, maintenant: horloge.maintenant().timeIntervalSince1970) } catch {
            try? FileManager.default.removeItem(at: temporaire)
            throw error
        }
        let url = try EcritureNote.publier(temporaire, nomDeBase: nomDeBase, dans: inbox)
        ligne.statut = statut
        ligne.note = url.lastPathComponent
        ligne.ecriture = nil
        try base.enregistrer(ligne, maintenant: horloge.maintenant().timeIntervalSince1970)
        return url
    }

    /// Termine les écritures interrompues : le fichier temporaire encore là est renommé ; sinon le renommage
    /// avait eu lieu. Puis retire les fichiers temporaires de Vocal restés dans l'inbox.
    private func reprendreEcritures(_ base: BaseEtat, inbox: URL, journal: Journal) throws {
        let fm = FileManager.default
        for var ligne in try base.ecrituresInterrompues() {
            guard let ecriture = ligne.ecriture else { continue }
            let temporaire = inbox.appendingPathComponent(ecriture.temporaire)
            if fm.fileExists(atPath: temporaire.path) {
                ligne.note = try EcritureNote.publier(temporaire, nomDeBase: ecriture.nomDeBase, dans: inbox).lastPathComponent
            }
            ligne.statut = ecriture.statut
            ligne.ecriture = nil
            try base.enregistrer(ligne, maintenant: horloge.maintenant().timeIntervalSince1970)
            journal.ecrire("mémo \(identite(ligne)) : écriture de la note reprise après une coupure")
        }
        for nom in (try? fm.contentsOfDirectory(atPath: inbox.path)) ?? []
        where nom.hasPrefix(EcritureNote.prefixeTemporaire) && nom.hasSuffix(EcritureNote.suffixeTemporaire) {
            try? fm.removeItem(at: inbox.appendingPathComponent(nom))
        }
    }

    /// Copie l'audio dans le cache de Vocal, sous son nom, dans un dossier propre à ce traitement.
    private func copierEnCache(_ audio: URL, dans cache: URL) throws -> URL {
        let dossier = cache.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dossier, withIntermediateDirectories: true)
        let copie = dossier.appendingPathComponent(audio.lastPathComponent)
        do { try FileManager.default.copyItem(at: audio, to: copie) } catch {
            try? FileManager.default.removeItem(at: dossier)
            throw error
        }
        return copie
    }
}

/// Identité d'un mémo dans le journal : son numéro dans l'état, et son nom de fichier s'il a la forme
/// du Dictaphone (date, heure et identifiant court), qui ne dit rien de son contenu.
func identite(_ ligne: LigneMemo) -> String {
    let nom = (ligne.fichier as NSString).deletingPathExtension
    return nom.wholeMatch(of: /\d{8} \d{6}-[0-9A-Za-z]+/) != nil ? "n°\(ligne.numero) (\(nom))" : "n°\(ligne.numero)"
}

func estDossier(_ url: URL) -> Bool {
    var dossier: ObjCBool = false
    return FileManager.default.fileExists(atPath: url.path, isDirectory: &dossier) && dossier.boolValue
}

/// Un fichier audio du dossier des enregistrements, tel qu'observé.
struct FichierObserve {
    let url: URL
    /// Nom du fichier : c'est la clé du mémo dans l'état.
    let nom: String
    let taille: Int64
    let modification: Double

    /// Vrai pour un remplacement iCloud `.<nom>.icloud` : l'audio n'est pas encore téléchargé.
    var estRemplacement: Bool { url.lastPathComponent != nom }
}

/// Parcours du dossier des enregistrements.
struct Releve {
    static let extensions: Set<String> = ["m4a", "qta"]

    let fichiers: [FichierObserve]
    /// Faux si un sous-dossier n'a pas pu être lu : l'absence d'un mémo ne prouve alors rien.
    let complet: Bool

    /// Fichiers `.m4a` et `.qta`, en parcourant les sous-dossiers, hors fichiers et dossiers cachés.
    /// Avec `avecRemplacements`, un remplacement iCloud `.<nom>.icloud` compte pour le mémo `<nom>`.
    /// Un nom présent deux fois ne compte qu'une fois.
    static func memos(_ dossier: URL, avecRemplacements: Bool = false) throws -> Releve {
        let fm = FileManager.default
        guard (try? fm.contentsOfDirectory(atPath: dossier.path)) != nil else {
            throw ErreurPassage.enregistrementsIllisibles(dossier.path)
        }
        var trouves: [String: FichierObserve] = [:]
        var complet = true
        var aVisiter = [dossier]
        while let courant = aVisiter.popLast() {
            guard let noms = try? fm.contentsOfDirectory(atPath: courant.path) else { complet = false; continue }
            for nom in noms.sorted() {
                let url = courant.appendingPathComponent(nom)
                if nom.hasPrefix(".") {
                    guard avecRemplacements, nom.hasSuffix(".icloud") else { continue }
                    let vrai = String(nom.dropFirst().dropLast(".icloud".count))
                    guard extensions.contains((vrai as NSString).pathExtension.lowercased()), trouves[vrai] == nil else { continue }
                    trouves[vrai] = FichierObserve(url: url, nom: vrai, taille: 0, modification: 0)
                    continue
                }
                let valeurs = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
                if valeurs?.isDirectory == true { aVisiter.append(url); continue }
                guard extensions.contains(url.pathExtension.lowercased()), trouves[nom] == nil else { continue }
                trouves[nom] = FichierObserve(url: url, nom: nom, taille: Int64(valeurs?.fileSize ?? 0),
                                              modification: valeurs?.contentModificationDate?.timeIntervalSince1970 ?? 0)
            }
        }
        return Releve(fichiers: trouves.values.sorted { $0.nom < $1.nom }, complet: complet)
    }

    /// Le même relevé, sans les mémos écartés.
    func sans(_ ecarte: (String) -> Bool) -> Releve {
        Releve(fichiers: fichiers.filter { !ecarte($0.nom) }, complet: complet)
    }
}

/// Verrou exclusif d'un passage, posé avec `flock` : il tombe avec le processus.
final class Verrou {
    private let descripteur: Int32

    init(_ fichier: URL) throws {
        descripteur = open(fichier.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard descripteur >= 0 else { throw ErreurPassage.verrouImpossible }
        guard flock(descripteur, LOCK_EX | LOCK_NB) == 0 else {
            close(descripteur)
            throw ErreurPassage.dejaEnCours
        }
    }

    func liberer() { close(descripteur) }
}

/// Journal des passages : une ligne datée par événement, jamais le texte d'un mémo. Une écriture
/// impossible dans le journal n'arrête pas le passage : les notes comptent plus que leur trace.
struct Journal {
    let fichier: URL
    let horloge: any Horloge

    init(_ fichier: URL, horloge: any Horloge) {
        self.fichier = fichier
        self.horloge = horloge
    }

    func ecrire(_ ligne: String) {
        let fm = FileManager.default
        try? fm.createDirectory(at: fichier.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: fichier.path) { fm.createFile(atPath: fichier.path, contents: nil) }
        guard let poignee = try? FileHandle(forWritingTo: fichier) else { return }
        defer { try? poignee.close() }
        _ = try? poignee.seekToEnd()
        let date = ISO8601DateFormatter().string(from: horloge.maintenant())
        try? poignee.write(contentsOf: Data("\(date) \(ligne)\n".utf8))
    }
}

/// Suivi de la stabilité des mémos pendant un passage.
struct Suivi {
    let base: BaseEtat
    var memos: [String: LigneMemo]
    let horloge: any Horloge
    /// Mémos stables, à traiter, dans l'ordre de leur nom.
    private(set) var prets: [FichierObserve] = []
    /// Mémos `vu` présents mais pas encore stables, à la dernière observation.
    private var enObservation: Set<String> = []
    /// Noms de tous les fichiers présents à la dernière observation.
    private var presents: Set<String> = []

    init(base: BaseEtat, memos: [String: LigneMemo], horloge: any Horloge) {
        self.base = base
        self.memos = memos
        self.horloge = horloge
    }

    /// Une observation : un mémo nouveau est noté `vu` ; un mémo `vu` inchangé depuis 12 s au moins est prêt ;
    /// un mémo `vu` qui a changé repart de zéro ; un mémo `vu` disparu d'un relevé complet est oublié.
    mutating func observer(_ releve: Releve) throws {
        let t = horloge.maintenant().timeIntervalSince1970
        enObservation = []
        let dejaPrets = Set(prets.map(\.nom))
        for f in releve.fichiers where !dejaPrets.contains(f.nom) {
            guard var ligne = memos[f.nom] else {
                memos[f.nom] = try base.inserer(f, statut: .vu, maintenant: t)
                enObservation.insert(f.nom)
                continue
            }
            guard ligne.statut == .vu else { continue }
            if ligne.taille != f.taille || ligne.modification != f.modification {
                ligne.taille = f.taille
                ligne.modification = f.modification
                ligne.observeLe = t
                try base.enregistrer(ligne, maintenant: t)
                memos[f.nom] = ligne
                enObservation.insert(f.nom)
            } else if t - ligne.observeLe >= Passage.delaiDeStabilite {
                prets.append(f)
            } else {
                enObservation.insert(f.nom)
            }
        }
        presents = Set(releve.fichiers.map(\.nom))
        if releve.complet {
            for ligne in memos.values where ligne.statut == .vu && !presents.contains(ligne.fichier) {
                try base.supprimer(ligne.numero)
                memos[ligne.fichier] = nil
            }
        }
        prets.sort { $0.nom < $1.nom }
    }

    /// Temps à attendre pour qu'un mémo en observation puisse être déclaré stable, ou nil s'il n'y en a pas.
    func attenteRestante() -> TimeInterval? {
        let t = horloge.maintenant().timeIntervalSince1970
        return enObservation.compactMap { memos[$0] }.map { Passage.delaiDeStabilite - (t - $0.observeLe) }.max()
    }

    /// Mémos présents encore `vu` : en observation, ou en échec de transcription à réessayer.
    var enAttente: Int { presents.count(where: { memos[$0]?.statut == .vu }) }
}

struct AudioIllisible: Error {}

/// Nature d'un échec pour le journal, sans contenu ni chemin.
func nature(_ erreur: any Error) -> String {
    switch erreur {
    case let e as ErreurTranscription: return e.description
    case is AudioIllisible: return "audio illisible"
    case let e as any ErreurSansContenu: return e.description
    default:
        let ns = erreur as NSError
        return "\(String(describing: type(of: erreur))) \(ns.domain) \(ns.code)"
    }
}

/// Une durée en secondes, avec un chiffre après la virgule.
func secondes(_ d: Duration) -> String {
    String(format: "%.1f s", Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18)
}

extension IssueRedaction {
    /// Libellé pour le journal, sans contenu : la raison d'un rejet ne recopie jamais la réponse.
    var libelle: String {
        switch self {
        case .sansLLM: return "sans LLM"
        case .redigee: return "faite"
        case let .rejetee(raison): return "rejetée (\(raison))"
        }
    }
}
