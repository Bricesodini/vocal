import Foundation

/// Le temps d'un passage : l'heure, et l'attente entre deux observations d'un mémo.
public protocol Horloge: Sendable {
    func maintenant() -> Date
    func attendre(_ secondes: TimeInterval) async
}

/// L'horloge du Mac.
public struct HorlogeSysteme: Horloge {
    public init() {}
    public func maintenant() -> Date { Date() }
    public func attendre(_ secondes: TimeInterval) async {
        try? await Task.sleep(for: .seconds(secondes))
    }
}
