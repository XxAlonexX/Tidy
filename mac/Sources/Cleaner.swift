import Foundation

/// Swift port of jev_cleaner.py: rules for obvious files, a Jev Choice for the rest,
/// and moves recorded in the same `.jev-cleaner-manifest.json` format so either tool can undo.
enum Categories {
    static let ordered: [(name: String, rubric: String)] = [
        ("Screenshots", "A screen capture of a computer or phone display, e.g. macOS 'Screenshot 2025-…' or 'CleanShot' files."),
        ("Recordings", "A screen recording or captured screen video, e.g. 'Screen Recording 2025-…'."),
        ("Videos", "A video that is not a screen recording: movies, clips, exported edits, demo videos."),
        ("Audio", "Music, podcasts, voice memos, or other sound files."),
        ("Images", "Photos, logos, graphics, designs, or other pictures that are not screen captures."),
        ("Docs", "Documents meant to be read: PDFs, notes, papers, slides, spreadsheets, Markdown, text."),
        ("Code", "Source code, scripts, config files, notebooks, or developer data files."),
        ("Archives", "Compressed archives and installers: zip, tar, dmg, pkg."),
        ("Other", "Anything that does not clearly fit the other folders."),
    ]
    static var names: [String] { ordered.map(\.name) }
}

private let extCategory: [String: String] = {
    var m: [String: String] = [:]
    for e in ["mp3", "wav", "m4a", "aac", "flac", "ogg", "aiff", "opus"] { m[e] = "Audio" }
    for e in ["pdf", "doc", "docx", "pages", "ppt", "pptx", "key", "xls", "xlsx", "numbers", "csv", "rtf", "epub", "odt"] { m[e] = "Docs" }
    for e in ["py", "js", "ts", "tsx", "jsx", "sh", "zsh", "rb", "go", "rs", "java", "kt", "swift", "c", "cc", "cpp",
              "h", "hpp", "cs", "php", "sql", "ipynb", "yaml", "yml", "toml", "css", "scss"] { m[e] = "Code" }
    for e in ["zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar", "dmg", "pkg", "iso"] { m[e] = "Archives" }
    return m
}()
private let imageExts: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "webp", "tiff", "bmp", "svg"]
private let videoExts: Set<String> = ["mp4", "mov", "m4v", "avi", "mkv", "webm"]
private let textExts: Set<String> = ["txt", "md", "json", "html", "xml", "log", "ini", "env", ""]

private func matches(_ name: String, _ pattern: String) -> Bool {
    name.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
}

func ruleCategory(_ url: URL) -> String? {
    let ext = url.pathExtension.lowercased(), name = url.lastPathComponent
    if imageExts.contains(ext) && matches(name, #"^(Screenshot|Screen Shot|CleanShot)\b"#) { return "Screenshots" }
    if videoExts.contains(ext) && matches(name, #"^(Screen Recording|CleanShot)\b"#) { return "Recordings" }
    return extCategory[ext]
}

/// Context Jev needs to judge a file: name, type, size, and a peek at text content.
func fileState(_ url: URL) -> [String: Any] {
    let ext = url.pathExtension.lowercased()
    let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
    let size = values?.fileSize ?? 0
    let day = DateFormatter()
    day.dateFormat = "yyyy-MM-dd"
    var state: [String: Any] = [
        "filename": url.lastPathComponent,
        "extension": ext.isEmpty ? NSNull() : ext,
        "size_kb": (Double(size) / 1024 * 10).rounded() / 10,
        "modified": day.string(from: values?.contentModificationDate ?? Date()),
    ]
    if textExts.contains(ext), size < 2_000_000, let handle = try? FileHandle(forReadingFrom: url) {
        defer { try? handle.close() }
        if let data = try? handle.read(upToCount: 2400), let text = String(data: data, encoding: .utf8) {
            state["text_preview"] = String(text.prefix(600))
        }
    }
    return state
}

enum JevError: LocalizedError {
    case badKey
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .badKey: return "TypeSafe rejected the API key"
        case let .http(code, body): return "HTTP \(code): \(body)"
        }
    }
}

enum Jev {
    static let endpoint = URL(string: "https://api.typesafe.ai/v1/systemone")!

    static func folderRequestBody(state: [String: Any]) throws -> Data {
        var criteria: [String: String] = [:]
        for c in Categories.ordered { criteria[c.name] = c.rubric }
        return try JSONSerialization.data(withJSONObject: [
            "model": "jev-latest",
            "state": state,
            "questions": [
                "folder": [
                    "type": "choice",
                    "instructions": "This file is sitting on a cluttered desktop. Which folder should it be moved into? "
                        + "Judge from `filename`, `extension`, and `text_preview` if present.",
                    "criteria": criteria,
                ],
            ],
        ])
    }

    /// Sends one prepared request; retries rate limits, server errors, and network failures.
    static func ask(body: Data, apiKey: String, retries: Int = 4) async throws -> (category: String, confidence: Double) {
        var req = URLRequest(url: endpoint, timeoutInterval: 30)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        for attempt in 0...retries {
            do {
                let (data, resp) = try await URLSession.shared.data(for: req)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                if code == 200 {
                    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                    let answers = json?["answers"] as? [String: Any]
                    // Echo back whichever question id was asked.
                    if let answer = answers?.values.first as? [String: Any] {
                        if let choice = answer["choice"] as? String {
                            return (choice, (answer["confidence"] as? NSNumber)?.doubleValue ?? 0)
                        }
                        if let noul = answer["noul"] as? NSNumber { return ("noul", noul.doubleValue) }
                    }
                    throw JevError.http(code, "unexpected response")
                }
                if code == 401 || code == 403 { throw JevError.badKey }
                if ![429, 500, 502, 503, 504].contains(code) || attempt == retries {
                    throw JevError.http(code, String(decoding: data.prefix(160), as: UTF8.self))
                }
            } catch let error as URLError {
                if attempt == retries { throw error }
            }
            try await Task.sleep(nanoseconds: UInt64(pow(2.0, Double(attempt)) * 1_000_000_000))
        }
        throw JevError.http(0, "retries exhausted")
    }

    /// Cheap call used to check a key when the user saves it.
    static func check(apiKey: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: [
            "model": "jev-latest", "state": "hello",
            "questions": ["ok": ["type": "noul", "instructions": "Is this a greeting?"]],
        ])
        _ = try await ask(body: body, apiKey: apiKey, retries: 1)
    }
}

/// One Jev answer, in a form that can cross from worker tasks back to the main actor.
enum JevOutcome: Sendable {
    case answer(String, Double)
    case failure(String)

    static func ask(body: Data, apiKey: String) async -> JevOutcome {
        do {
            let a = try await Jev.ask(body: body, apiKey: apiKey)
            return .answer(a.category, a.confidence)
        } catch {
            return .failure(String(error.localizedDescription.prefix(160)))
        }
    }
}

@MainActor
final class Cleaner {
    private(set) var root: URL?
    private(set) var files: [String: URL] = [:]
    private var results: [String: [String: Any]] = [:]
    private var running: Task<Void, Never>?
    private var currentRun = UUID()

    static let manifestName = ".jev-cleaner-manifest.json"

    func scan(_ folder: URL) throws -> [String: Any] {
        let urls = try FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]
        )
        .filter {
            let v = try? $0.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            return v?.isRegularFile == true && v?.isSymbolicLink != true
        }
        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

        running?.cancel()
        currentRun = UUID()
        root = folder
        results = [:]
        files = [:]
        var list: [[String: Any]] = []
        for (i, url) in urls.enumerated() {
            let id = String(i)
            files[id] = url
            list.append(["id": id, "name": url.lastPathComponent, "ext": url.pathExtension.lowercased()])
        }
        return ["root": folder.path, "categories": Categories.names, "files": list]
    }

    /// Streams one event per file to `emit`: rule hits first (shuffled), then Jev answers as they land.
    func classify(threshold: Double, allJev: Bool, apiKey: String?, workers: Int = 8, emit: @escaping @MainActor ([String: Any]) -> Void) {
        running?.cancel()
        results = [:]
        var ruleHits: [[String: Any]] = []
        var toAsk: [(id: String, body: Data)] = []
        var noKey: [String] = []
        for (id, url) in files {
            if !allJev, let cat = ruleCategory(url) {
                ruleHits.append(["id": id, "category": cat, "confidence": NSNull(), "source": "rule", "status": "ok"])
            } else if apiKey == nil {
                noKey.append(id)
            } else if let body = try? Jev.folderRequestBody(state: fileState(url)) {
                toAsk.append((id, body))
            }
        }
        emit(["type": "start", "rules": ruleHits.count, "jev": toAsk.count, "nokey": noKey.count])
        for r in ruleHits.shuffled() {
            results[r["id"] as! String] = r
            emit(r)
        }
        for id in noKey {
            let r: [String: Any] = ["id": id, "category": NSNull(), "confidence": NSNull(), "source": "jev", "status": "nokey"]
            results[id] = r
            emit(r)
        }

        let run = UUID()
        currentRun = run
        let jobs = toAsk
        let key = apiKey ?? ""
        // Workers only do network I/O; every result is handed back to the main actor, which owns
        // `results` and the web view. Results from a superseded run (rescan, new clean) are dropped.
        running = Task.detached { [weak self] in
            await withTaskGroup(of: (String, JevOutcome).self) { group in
                var pending = jobs[...]
                var inFlight = 0
                while !Task.isCancelled {
                    while inFlight < workers, let job = pending.popFirst() {
                        group.addTask { (job.id, await JevOutcome.ask(body: job.body, apiKey: key)) }
                        inFlight += 1
                    }
                    guard inFlight > 0, let (id, outcome) = await group.next() else { break }
                    inFlight -= 1
                    await self?.deliver(id: id, outcome: outcome, threshold: threshold, run: run, emit: emit)
                }
                group.cancelAll()
            }
            await self?.finish(run: run, emit: emit)
        }
    }

    private func deliver(id: String, outcome: JevOutcome, threshold: Double, run: UUID, emit: @MainActor ([String: Any]) -> Void) {
        guard run == currentRun else { return }
        var r: [String: Any] = ["id": id, "source": "jev"]
        switch outcome {
        case let .answer(category, confidence):
            r["category"] = category
            r["confidence"] = confidence
            r["status"] = confidence >= threshold ? "ok" : "review"
        case let .failure(message):
            r["category"] = NSNull()
            r["confidence"] = NSNull()
            r["status"] = "error"
            r["error"] = message
        }
        results[id] = r
        emit(r)
    }

    private func finish(run: UUID, emit: @MainActor ([String: Any]) -> Void) {
        guard run == currentRun else { return }
        emit(["type": "done"])
    }

    /// Moves every file classified "ok" in the last run, exactly as previewed.
    func move() throws -> Int {
        guard let root else { throw JevError.http(0, "Scan a folder first.") }
        let fm = FileManager.default
        var moves: [[String: String]] = []
        for (id, r) in results where r["status"] as? String == "ok" {
            guard let src = files[id], let cat = r["category"] as? String, fm.fileExists(atPath: src.path) else { continue }
            let dir = root.appendingPathComponent(cat, isDirectory: true)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let dest = uniqueDestination(dir.appendingPathComponent(src.lastPathComponent))
            try fm.moveItem(at: src, to: dest)
            moves.append(["from": src.path, "to": dest.path])
        }
        guard !moves.isEmpty else { return 0 }
        let manifest = root.appendingPathComponent(Cleaner.manifestName)
        var history = (try? JSONSerialization.jsonObject(with: Data(contentsOf: manifest))) as? [[String: Any]] ?? []
        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime, .withDashSeparatorInDate]
        stamp.timeZone = .current
        history.append(["at": stamp.string(from: Date()), "moves": moves])
        try JSONSerialization.data(withJSONObject: history, options: .prettyPrinted).write(to: manifest)
        results = [:]
        return moves.count
    }

    /// Reverts the most recent move run recorded in the folder's manifest.
    func undo() throws -> Int {
        guard let root else { throw JevError.http(0, "Scan a folder first.") }
        let fm = FileManager.default
        let manifest = root.appendingPathComponent(Cleaner.manifestName)
        guard var history = (try? JSONSerialization.jsonObject(with: Data(contentsOf: manifest))) as? [[String: Any]],
              let run = history.popLast(), let moves = run["moves"] as? [[String: String]]
        else { throw JevError.http(0, "Nothing to undo.") }
        var restored = 0
        for m in moves.reversed() {
            guard let to = m["to"], let from = m["from"], fm.fileExists(atPath: to) else { continue }
            try fm.moveItem(at: URL(fileURLWithPath: to), to: uniqueDestination(URL(fileURLWithPath: from)))
            restored += 1
        }
        for cat in Categories.names {
            let dir = root.appendingPathComponent(cat, isDirectory: true)
            if let items = try? fm.contentsOfDirectory(atPath: dir.path), items.isEmpty { try? fm.removeItem(at: dir) }
        }
        if history.isEmpty {
            try? fm.removeItem(at: manifest)
        } else {
            try JSONSerialization.data(withJSONObject: history, options: .prettyPrinted).write(to: manifest)
        }
        return restored
    }

    private func uniqueDestination(_ dest: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: dest.path) else { return dest }
        let stem = dest.deletingPathExtension().lastPathComponent, ext = dest.pathExtension
        for i in 1..<10_000 {
            let name = ext.isEmpty ? "\(stem) (\(i))" : "\(stem) (\(i)).\(ext)"
            let candidate = dest.deletingLastPathComponent().appendingPathComponent(name)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
        }
        return dest
    }
}
