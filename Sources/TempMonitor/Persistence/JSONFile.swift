import Foundation

/// A Codable value stored as JSON on disk. Dates are written as seconds since 1970.
struct JSONFile<Value: Codable> {
    let url: URL

    /// Returns nil if the file is missing or can't be decoded.
    func load() -> Value? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(Value.self, from: data)
    }

    func save(_ value: Value) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(value) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

enum AppSupport {
    /// `~/Library/Application Support/TempMonitor/<name>`.
    static func file(_ name: String) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TempMonitor", isDirectory: true)
            .appendingPathComponent(name)
    }
}
