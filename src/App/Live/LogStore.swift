import Foundation

/// CSV data logs in ~/Documents/OpenLink Tuner/Logs. Recordings from this app land here, and any
/// CSV dropped in (e.g. a log exported from PCLink) shows up in the list and on the iPhone.
final class LogStore {
    let folder: URL = {
        let u = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenLink Tuner/Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()

    private var handle: FileHandle?
    private var startT: Double?
    private(set) var currentFile: URL?

    func start(channels: [PhoneLink.Channel]) {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH-mm-ss"
        let name = "Log \(f.string(from: Date())).csv"
        let url = folder.appendingPathComponent(name)
        let header = (["Time (s)"] + channels.map { "\($0.name) [\($0.unit)] (D\($0.id))" })
            .map { "\"\($0)\"" }.joined(separator: ",") + "\n"
        FileManager.default.createFile(atPath: url.path, contents: Data(header.utf8))
        handle = try? FileHandle(forWritingTo: url)
        handle?.seekToEndOfFile()
        startT = nil
        currentFile = url
    }

    func append(_ f: PhoneLink.Frame) {
        guard let h = handle else { return }
        if startT == nil { startT = f.t }
        let row = ([String(format: "%.3f", f.t - (startT ?? f.t))] + f.values.map { $0.map { String(format: "%.4g", $0) } ?? "" })
            .joined(separator: ",") + "\n"
        h.write(Data(row.utf8))
    }

    func finish() {
        try? handle?.close(); handle = nil; currentFile = nil
    }

    func list() -> [PhoneLink.LogInfo] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])) ?? []
        return urls.filter { $0.pathExtension.lowercased() == "csv" }.compactMap(info).sorted { $0.date > $1.date }
    }

    func info(_ url: URL) -> PhoneLink.LogInfo? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let lines = text.split(whereSeparator: \.isNewline)
        guard let head = lines.first else { return nil }
        let cols = head.split(separator: ",").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\" ")) }
        func t(_ l: Substring?) -> Double? { l.flatMap { Double($0.split(separator: ",").first ?? "") } }
        let dur = (t(lines.last) ?? 0) - (t(lines.dropFirst().first) ?? 0)
        let attrs = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        return PhoneLink.LogInfo(id: url.lastPathComponent, date: attrs?.contentModificationDate ?? Date(),
                                 duration: max(0, dur), samples: max(0, lines.count - 1),
                                 bytes: attrs?.fileSize ?? 0, channels: Array(cols.dropFirst()))
    }

    func read(_ name: String) -> String? {
        let url = folder.appendingPathComponent((name as NSString).lastPathComponent)  // no path traversal
        return try? String(contentsOf: url, encoding: .utf8)
    }

    func importCSV(_ src: URL) throws {
        let dst = folder.appendingPathComponent(src.lastPathComponent)
        if FileManager.default.fileExists(atPath: dst.path) { try FileManager.default.removeItem(at: dst) }
        try FileManager.default.copyItem(at: src, to: dst)
    }
}
