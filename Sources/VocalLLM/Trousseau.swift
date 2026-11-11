import Foundation
import Security

/// Lit une clé d'API par son nom d'entrée. Injectée, pour que les tests ne touchent jamais le vrai trousseau.
public typealias LectureTrousseau = @Sendable (_ nom: String) throws -> String

public enum Trousseau {
    /// Mot de passe générique du trousseau de session dont le service vaut `nom`.
    /// Entrée à créer par l'utilisateur : `security add-generic-password -s <nom> -a vocal -w`.
    public static let lire: LectureTrousseau = { nom in
        let requete: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: nom,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var resultat: CFTypeRef?
        let statut = SecItemCopyMatching(requete as CFDictionary, &resultat)
        guard statut != errSecItemNotFound else { throw ErreurRedacteur.cleIntrouvable(nom) }
        guard statut == errSecSuccess, let donnees = resultat as? Data, let cle = String(data: donnees, encoding: .utf8) else {
            throw ErreurRedacteur.trousseau(statut)
        }
        return cle.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
