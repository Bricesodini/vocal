// Pose titre, encodeur et date de création sur un fichier audio, dans les clés iTunes
// qu'utilise le Dictaphone. Outil de développement pour les fichiers de test.
// Usage : swift scripts/tag-audio.swift <entrée> <sortie> <m4a|mov> <encodeur|-> <titre|-> <date ISO|-> [uuid]
import AVFoundation

let a = CommandLine.arguments
guard a.count == 7 || a.count == 8 else { FileHandle.standardError.write(Data("usage incorrect\n".utf8)); exit(2) }
let (input, output, kind, encoder, title, date) = (a[1], a[2], a[3], a[4], a[5], a[6])
let uuid = a.count == 8 ? a[7] : nil

func item(_ key: String, _ value: String) -> AVMetadataItem {
    let m = AVMutableMetadataItem()
    m.keySpace = .iTunes
    m.key = key as NSString
    m.value = value as NSString
    return m.copy() as! AVMetadataItem
}

let asset = AVURLAsset(url: URL(fileURLWithPath: input))
guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else { exit(3) }
var items: [AVMetadataItem] = []
if encoder != "-" { items.append(item("\u{00A9}too", encoder)) }
if title != "-" { items.append(item("\u{00A9}nam", title)) }
if date != "-" {
    let m = AVMutableMetadataItem()
    m.keySpace = .common
    m.key = AVMetadataKey.commonKeyCreationDate as NSString
    m.value = date as NSString
    items.append(m.copy() as! AVMetadataItem)
}
if let uuid {
    // Clé longue iTunes du Dictaphone : itlk/com.apple.iTunes.voice-memo-uuid.
    let m = AVMutableMetadataItem()
    m.identifier = AVMetadataItem.identifier(forKey: "com.apple.iTunes.voice-memo-uuid", keySpace: AVMetadataKeySpace(rawValue: "itlk"))
    m.value = uuid as NSString
    m.dataType = kCMMetadataBaseDataType_UTF8 as String
    items.append(m.copy() as! AVMetadataItem)
}
export.metadata = items
let out = URL(fileURLWithPath: output)
try? FileManager.default.removeItem(at: out)
do {
    try await export.export(to: out, as: kind == "mov" ? .mov : .m4a)
} catch {
    FileHandle.standardError.write(Data("échec : \(error)\n".utf8))
    exit(1)
}
