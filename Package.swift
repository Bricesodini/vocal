// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Vocal",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "Vocal", targets: ["Vocal"]),
    ],
    targets: [
        // Domaine : note vocale, métadonnées du mémo, commande essai. Ne dépend pas de Speech.
        .target(name: "VocalCore"),
        // Adaptateur : transcription et modèle Apple (Speech, SpeechAnalyzer).
        .target(name: "VocalSpeech", dependencies: ["VocalCore"]),
        // Adaptateur : rédacteur LLM (protocoles openai-compatible et anthropic) et trousseau macOS.
        .target(name: "VocalLLM", dependencies: ["VocalCore"]),
        // Exécutable : lit la ligne de commande et branche les adaptateurs réels.
        .executableTarget(name: "Vocal", dependencies: ["VocalCore", "VocalSpeech", "VocalLLM"]),
        .testTarget(name: "VocalCoreTests", dependencies: ["VocalCore"]),
        .testTarget(name: "VocalSpeechTests", dependencies: ["VocalSpeech"]),
        .testTarget(name: "VocalLLMTests", dependencies: ["VocalLLM", "VocalCore"]),
    ]
)
