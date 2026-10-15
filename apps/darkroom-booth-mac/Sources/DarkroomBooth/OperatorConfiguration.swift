import BoothCore
import Foundation

/// Operator choices persisted between launches (the Windows app kept these
/// in the registry under `HKCU\Software\Darkroom Software\Options` and in the
/// event's settings).
struct OperatorConfiguration: Codable, Equatable {
    var eventName = "Booth Event"
    var eventDirectoryPath: String?
    var cameraID: String?
    var hotFolderPaths: [String] = []
    var printerName: String?
    var layoutID = PrintLayout.strip(photos: 4).id
    var settings = BoothSettings()

    private static let defaultsKey = "OperatorConfiguration"

    static func load() -> OperatorConfiguration {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let value = try? JSONDecoder().decode(OperatorConfiguration.self, from: data)
        else { return OperatorConfiguration() }
        return value
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }

    var eventDirectory: URL {
        if let eventDirectoryPath { return URL(fileURLWithPath: eventDirectoryPath, isDirectory: true) }
        let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return pictures.appendingPathComponent("Darkroom Booth", isDirectory: true)
            .appendingPathComponent(eventName, isDirectory: true)
    }
}
