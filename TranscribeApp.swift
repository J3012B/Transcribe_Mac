import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers

// ============================================================================
// Transcribe — self-contained, offline audio/video transcription.
// Bundles whisper.cpp (CoreML + Metal) inside the .app; converts audio with
// AVFoundation (no ffmpeg); downloads the model on first launch.
// ============================================================================

let MODEL_STEM = "ggml-small"
let MODEL_BIN_URL  = URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin")!
let MODEL_COREML_ZIP_URL = URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small-encoder.mlmodelc.zip")!
let MODEL_TOTAL_BYTES: Int64 = 651_000_000   // ~ bin (487MB) + coreml (163MB), for progress

// Helper tools for the optional "transcribe from a URL" feature. These are NOT
// bundled — they're downloaded on demand the first time the user opens that
// feature, so the app stays small for people who never touch it.
let YTDLP_URL  = URL(string: "https://github.com/yt-dlp/yt-dlp/releases/download/2026.07.04/yt-dlp_macos")!
let FFMPEG_URL = URL(string: "https://github.com/eugeneware/ffmpeg-static/releases/download/b6.1.1/ffmpeg-darwin-arm64.gz")!
let DENO_URL   = URL(string: "https://github.com/denoland/deno/releases/download/v2.9.5/deno-aarch64-apple-darwin.zip")!

// Where the in-app "Support" button sends people (same link as the website + README).
let DONATE_URL = URL(string: "https://donate.stripe.com/14AdR8fWj0ts8CUeoGd3i00")!

let SUPPORTED: Set<String> = ["m4a","mp3","wav","aiff","aif","caf","flac","mp4","mov",
                              "m4v","aac","3gp","amr","au","ogg","oga","opus","webm"]

// MARK: - Paths

enum Paths {
    static var support: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Transcribe", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    static var modelsDir: URL {
        let d = support.appendingPathComponent("models", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    static var modelBin: URL { modelsDir.appendingPathComponent("\(MODEL_STEM).bin") }
    static var modelCoreML: URL { modelsDir.appendingPathComponent("\(MODEL_STEM)-encoder.mlmodelc") }
    // TRANSCRIBE_HISTORY overrides the history file (used to render demo screenshots
    // without touching real data).
    static var historyFile: URL {
        if let p = ProcessInfo.processInfo.environment["TRANSCRIBE_HISTORY"], !p.isEmpty {
            return URL(fileURLWithPath: p)
        }
        return support.appendingPathComponent("history.json")
    }
    // Bundled binary: Contents/Resources/whisper/bin/whisper-cli
    static var whisperBin: URL {
        Bundle.main.resourceURL!.appendingPathComponent("whisper/bin/whisper-cli")
    }
    // Helper tools (yt-dlp, deno, ffmpeg) downloaded on demand for the URL feature.
    static var toolsDir: URL {
        let d = support.appendingPathComponent("tools", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    static func downloadedTool(_ name: String) -> String? {
        let p = toolsDir.appendingPathComponent(name).path
        return FileManager.default.isExecutableFile(atPath: p) ? p : nil
    }
}

// MARK: - Model manager

enum ModelState: Equatable {
    case ready
    case missing
    case downloading(Double)   // 0...1
    case failed(String)
}

final class ModelManager: NSObject, ObservableObject {
    @Published var state: ModelState = .missing
    private var session: URLSession!
    private var received: Int64 = 0

    override init() {
        super.init()
        session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        refresh()
    }

    func refresh() {
        let fm = FileManager.default
        if fm.fileExists(atPath: Paths.modelBin.path) && fm.fileExists(atPath: Paths.modelCoreML.path) {
            state = .ready
        } else {
            state = .missing
        }
    }

    func startDownload() {
        state = .downloading(0)
        received = 0
        // Step 1: the ggml bin.
        let t = session.downloadTask(with: MODEL_BIN_URL)
        t.taskDescription = "bin"
        t.resume()
    }

    private func fail(_ msg: String) {
        DispatchQueue.main.async { self.state = .failed(msg) }
    }
}

extension ModelManager: URLSessionDownloadDelegate {
    func urlSession(_ s: URLSession, downloadTask t: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        // Progress across both files, approximated against MODEL_TOTAL_BYTES.
        let base: Int64 = (t.taskDescription == "coreml") ? 487_000_000 : 0
        let frac = Double(base + totalBytesWritten) / Double(MODEL_TOTAL_BYTES)
        DispatchQueue.main.async { self.state = .downloading(min(0.99, max(0.01, frac))) }
    }

    func urlSession(_ s: URLSession, downloadTask t: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        let fm = FileManager.default
        do {
            if t.taskDescription == "bin" {
                try? fm.removeItem(at: Paths.modelBin)
                try fm.moveItem(at: location, to: Paths.modelBin)
                // Step 2: CoreML encoder zip.
                let c = session.downloadTask(with: MODEL_COREML_ZIP_URL)
                c.taskDescription = "coreml"
                c.resume()
            } else {
                // Unzip the mlmodelc into modelsDir using `ditto`.
                let zip = Paths.modelsDir.appendingPathComponent("coreml.zip")
                try? fm.removeItem(at: zip)
                try fm.moveItem(at: location, to: zip)
                try? fm.removeItem(at: Paths.modelCoreML)
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                p.arguments = ["-x", "-k", zip.path, Paths.modelsDir.path]
                try p.run(); p.waitUntilExit()
                try? fm.removeItem(at: zip)
                DispatchQueue.main.async { self.refresh() }
            }
        } catch {
            fail(error.localizedDescription)
        }
    }

    func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error { fail(error.localizedDescription) }
    }
}

// MARK: - Audio conversion (AVFoundation → 16kHz mono WAV)

enum AudioConvert {
    // Formats AVFoundation / Core Audio cannot decode on macOS; these need ffmpeg.
    static let needsExternalDecoder: Set<String> = ["ogg","oga","opus","webm"]

    static func toWav(_ input: URL) throws -> URL {
        // Ogg/Opus/WebM aren't decodable by AVFoundation — go straight to ffmpeg.
        if needsExternalDecoder.contains(input.pathExtension.lowercased()) {
            return try ffmpegToWav(input)
        }
        do {
            return try avfToWav(input)
        } catch {
            // AVFoundation failed (unusual container/codec) — try ffmpeg as a fallback.
            if ffmpegPath() != nil { return try ffmpegToWav(input) }
            throw error
        }
    }

    // MARK: AVFoundation path (fast, no external dependency)

    static func avfToWav(_ input: URL) throws -> URL {
        let asset = AVURLAsset(url: input)
        guard let track = asset.tracks(withMediaType: .audio).first else {
            throw NSError(domain: "Transcribe", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No audio track found."])
        }
        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1,
        ]
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        reader.add(out); reader.startReading()
        var pcm = Data()
        while reader.status == .reading {
            if let sb = out.copyNextSampleBuffer(), let bb = CMSampleBufferGetDataBuffer(sb) {
                var len = 0; var ptr: UnsafeMutablePointer<Int8>?
                CMBlockBufferGetDataPointer(bb, atOffset: 0, lengthAtOffsetOut: nil,
                                            totalLengthOut: &len, dataPointerOut: &ptr)
                if let ptr = ptr {
                    pcm.append(UnsafeBufferPointer(
                        start: UnsafeRawPointer(ptr).assumingMemoryBound(to: UInt8.self), count: len))
                }
                CMSampleBufferInvalidate(sb)
            }
        }
        guard reader.status == .completed else {
            throw NSError(domain: "Transcribe", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Could not decode this audio format."])
        }
        func u32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        func u16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        let sr: UInt32 = 16000, ch: UInt16 = 1, bits: UInt16 = 16
        var wav = Data()
        wav.append("RIFF".data(using: .ascii)!); wav.append(u32(UInt32(36 + pcm.count)))
        wav.append("WAVE".data(using: .ascii)!); wav.append("fmt ".data(using: .ascii)!)
        wav.append(u32(16)); wav.append(u16(1)); wav.append(u16(ch)); wav.append(u32(sr))
        wav.append(u32(sr * UInt32(ch) * UInt32(bits/8))); wav.append(u16(ch * (bits/8)))
        wav.append(u16(bits)); wav.append("data".data(using: .ascii)!)
        wav.append(u32(UInt32(pcm.count))); wav.append(pcm)
        let dst = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".wav")
        try wav.write(to: dst)
        return dst
    }

    // MARK: ffmpeg path (for Ogg Vorbis / Opus / WebM that AVFoundation can't decode)

    /// Locate an ffmpeg binary: the on-demand download, then Homebrew/system paths, then `which`.
    static func ffmpegPath() -> String? {
        if let dl = Paths.downloadedTool("ffmpeg") { return dl }
        for c in ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
        where FileManager.default.isExecutableFile(atPath: c) { return c }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["which", "ffmpeg"]
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        let path = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let path, !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) { return path }
        return nil
    }

    static func ffmpegToWav(_ input: URL) throws -> URL {
        guard let ffmpeg = ffmpegPath() else {
            throw NSError(domain: "Transcribe", code: 4, userInfo: [NSLocalizedDescriptionKey:
                "This format (\(input.pathExtension.lowercased())) needs ffmpeg, which isn't installed.\nInstall it with: brew install ffmpeg"])
        }
        let dst = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".wav")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ffmpeg)
        // Decode → 16 kHz mono signed-16 PCM WAV, matching the AVFoundation output.
        p.arguments = ["-hide_banner", "-loglevel", "error", "-nostdin", "-y",
                       "-i", input.path, "-ac", "1", "-ar", "16000",
                       "-c:a", "pcm_s16le", dst.path]
        let errPipe = Pipe(); p.standardError = errPipe; p.standardOutput = Pipe()
        try p.run(); p.waitUntilExit()
        guard p.terminationStatus == 0, FileManager.default.fileExists(atPath: dst.path) else {
            let e = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw NSError(domain: "Transcribe", code: 5, userInfo: [NSLocalizedDescriptionKey:
                "ffmpeg could not decode this file.\n\(e.trimmingCharacters(in: .whitespacesAndNewlines))"])
        }
        return dst
    }
}

// MARK: - YouTube (audio download via yt-dlp)

enum YouTube {
    /// Locate a yt-dlp binary: the on-demand download, then Homebrew/system paths, then `which`.
    static func ytDlpPath() -> String? { toolPath("yt-dlp") }

    /// Locate a deno binary (the JS runtime yt-dlp needs for YouTube).
    static func denoPath() -> String? { toolPath("deno") }

    /// Shared lookup: downloaded copy first, then common install dirs, then `which`.
    static func toolPath(_ name: String) -> String? {
        if let dl = Paths.downloadedTool(name) { return dl }
        for c in ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)", "/usr/bin/\(name)"]
        where FileManager.default.isExecutableFile(atPath: c) { return c }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["which", name]
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        let path = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let path, !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) { return path }
        return nil
    }

    /// True when every tool the URL feature needs is available.
    static var toolsReady: Bool {
        ytDlpPath() != nil && denoPath() != nil && AudioConvert.ffmpegPath() != nil
    }

    static func isURL(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let u = URL(string: t), let scheme = u.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    /// Download the best audio stream for a video URL. Returns (localFile, title).
    /// Prefers an m4a stream (decodable by AVFoundation, no ffmpeg needed).
    static func downloadAudio(_ urlString: String) throws -> (URL, String) {
        guard let yt = ytDlpPath() else {
            throw NSError(domain: "Transcribe", code: 10, userInfo: [NSLocalizedDescriptionKey:
                "The tools needed to download videos aren't set up yet."])
        }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: yt)
        var args = ["-f", "bestaudio[ext=m4a]/bestaudio/best",
                    "--no-playlist", "--no-progress",
                    "-o", dir.appendingPathComponent("%(title)s.%(ext)s").path]
        // yt-dlp may shell out to ffmpeg; point it at whichever copy we found.
        if let ff = AudioConvert.ffmpegPath() {
            args += ["--ffmpeg-location", ff]
        }
        // Recent yt-dlp needs a JS runtime for YouTube; point it at deno.
        if let deno = denoPath() {
            args += ["--js-runtimes", "deno:\(URL(fileURLWithPath: deno).deletingLastPathComponent().path)"]
        }
        args.append(urlString)
        p.arguments = args
        // Put the downloaded tools + Homebrew on PATH as a fallback for child processes.
        var env = ProcessInfo.processInfo.environment
        let extra = "\(Paths.toolsDir.path):/opt/homebrew/bin:/usr/local/bin"
        env["PATH"] = (env["PATH"].map { "\(extra):\($0)" }) ?? extra
        p.environment = env
        let errPipe = Pipe(); p.standardError = errPipe; p.standardOutput = Pipe()
        try p.run(); p.waitUntilExit()

        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil))?
            .filter { !$0.lastPathComponent.hasPrefix(".") } ?? []
        guard p.terminationStatus == 0, let file = files.first else {
            try? FileManager.default.removeItem(at: dir)
            let e = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw NSError(domain: "Transcribe", code: 11, userInfo: [NSLocalizedDescriptionKey:
                "Could not download audio from that link.\n\(e.trimmingCharacters(in: .whitespacesAndNewlines))"])
        }
        let title = file.deletingPathExtension().lastPathComponent
        return (file, title)
    }
}

// MARK: - SRT → readable timestamped text

enum SRT {
    /// Turn whisper's SRT output into compact lines like "[1:23] some words".
    static func toTimestamped(_ srt: String) -> String {
        var out: [String] = []
        let blocks = srt.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n\n")
        for block in blocks {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            guard let timeIdx = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let start = lines[timeIdx].components(separatedBy: "-->").first?
                .trimmingCharacters(in: .whitespaces) ?? ""
            let text = lines[(timeIdx + 1)...].joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)
            if text.isEmpty { continue }
            out.append("[\(stamp(start))] \(text)")
        }
        return out.joined(separator: "\n")
    }

    /// "00:01:23,456" → "1:23" (or "1:02:03" when there are hours).
    private static func stamp(_ s: String) -> String {
        let hms = s.split(separator: ",").first.map(String.init) ?? s
        let parts = hms.split(separator: ":").map { Int($0) ?? 0 }
        guard parts.count == 3 else { return hms }
        let (h, m, sec) = (parts[0], parts[1], parts[2])
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec)
                     : String(format: "%d:%02d", m, sec)
    }

    /// Remove the leading "[m:ss] " timestamp prefix from each line, for the
    /// "hide timestamps" view. Lines without a prefix (older plain transcripts)
    /// are passed through unchanged.
    static func stripTimestamps(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            let s = String(line)
            guard s.hasPrefix("["), let close = s.firstIndex(of: "]") else { return s }
            return String(s[s.index(after: close)...].drop { $0 == " " })
        }.joined(separator: "\n")
    }
}

// MARK: - Tools manager (on-demand download of yt-dlp / deno / ffmpeg)

enum ToolState: Equatable {
    case ready
    case missing
    case downloading(Double)   // 0...1
    case failed(String)
}

final class ToolsManager: NSObject, ObservableObject {
    struct Spec {
        let name: String       // final executable name in toolsDir
        let url: URL
        let kind: Kind
        let approxBytes: Int64 // download size estimate, for progress weighting
    }
    enum Kind { case raw, gzip, zip }

    @Published var state: ToolState = .missing

    private var session: URLSession!
    private var queue: [Spec] = []
    private var index = 0
    private var totalBytes: Int64 = 1
    private var doneBytes: Int64 = 0

    private let allSpecs = [
        Spec(name: "yt-dlp", url: YTDLP_URL,  kind: .raw,  approxBytes: 41_000_000),
        Spec(name: "ffmpeg", url: FFMPEG_URL, kind: .gzip, approxBytes: 28_000_000),
        Spec(name: "deno",   url: DENO_URL,   kind: .zip,  approxBytes: 39_000_000),
    ]

    override init() {
        super.init()
        session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        refresh()
    }

    func refresh() { state = YouTube.toolsReady ? .ready : .missing }

    /// Download whichever tools can't already be resolved on this machine.
    func startDownload() {
        queue = allSpecs.filter { spec in
            switch spec.name {
            case "yt-dlp": return YouTube.ytDlpPath() == nil
            case "deno":   return YouTube.denoPath() == nil
            case "ffmpeg": return AudioConvert.ffmpegPath() == nil
            default:       return true
            }
        }
        guard !queue.isEmpty else { refresh(); return }
        index = 0; doneBytes = 0
        totalBytes = queue.reduce(0) { $0 + $1.approxBytes }
        state = .downloading(0)
        next()
    }

    private func next() {
        guard index < queue.count else { DispatchQueue.main.async { self.refresh() }; return }
        session.downloadTask(with: queue[index].url).resume()
    }

    private func fail(_ msg: String) { DispatchQueue.main.async { self.state = .failed(msg) } }

    private func install(_ spec: Spec, from location: URL) throws {
        let fm = FileManager.default
        let dest = Paths.toolsDir.appendingPathComponent(spec.name)
        switch spec.kind {
        case .raw:
            try? fm.removeItem(at: dest)
            try fm.moveItem(at: location, to: dest)
        case .gzip:
            let gz = Paths.toolsDir.appendingPathComponent(spec.name + ".gz")
            try? fm.removeItem(at: gz); try? fm.removeItem(at: dest)
            try fm.moveItem(at: location, to: gz)
            try run("/usr/bin/gunzip", ["-f", gz.path])          // → dest
        case .zip:
            let zip = Paths.toolsDir.appendingPathComponent(spec.name + ".zip")
            try? fm.removeItem(at: zip); try? fm.removeItem(at: dest)
            try fm.moveItem(at: location, to: zip)
            try run("/usr/bin/ditto", ["-x", "-k", zip.path, Paths.toolsDir.path])
            try? fm.removeItem(at: zip)
        }
        guard fm.fileExists(atPath: dest.path) else {
            throw NSError(domain: "Transcribe", code: 12,
                          userInfo: [NSLocalizedDescriptionKey: "Could not unpack \(spec.name)."])
        }
        // Make it executable and clear quarantine so it can run.
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
        _ = try? run("/usr/bin/xattr", ["-d", "com.apple.quarantine", dest.path])
    }

    @discardableResult
    private func run(_ tool: String, _ args: [String]) throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = Pipe(); p.standardError = Pipe()
        try p.run(); p.waitUntilExit()
        return p.terminationStatus
    }
}

extension ToolsManager: URLSessionDownloadDelegate {
    func urlSession(_ s: URLSession, downloadTask t: URLSessionDownloadTask,
                    didWriteData: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let frac = Double(doneBytes + totalBytesWritten) / Double(totalBytes)
        DispatchQueue.main.async { self.state = .downloading(min(0.99, max(0.01, frac))) }
    }

    func urlSession(_ s: URLSession, downloadTask t: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        let spec = queue[index]
        do { try install(spec, from: location) }
        catch { fail(error.localizedDescription); return }
        doneBytes += spec.approxBytes
        index += 1
        next()
    }

    func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error { fail(error.localizedDescription) }
    }
}

func perfCores() -> Int {
    var n: Int32 = 0; var size = MemoryLayout<Int32>.size
    if sysctlbyname("hw.perflevel0.logicalcpu", &n, &size, nil, 0) == 0, n > 0 { return Int(n) }
    return max(4, ProcessInfo.processInfo.activeProcessorCount)
}

// MARK: - History model + store

struct Transcript: Identifiable, Codable, Hashable {
    var id = UUID(); var fileName: String; var filePath: String
    var date: Date; var text: String; var seconds: Double
}
struct RunningJob: Identifiable { let id = UUID(); var fileName: String; var start: Date }

final class Store: ObservableObject {
    @Published var items: [Transcript] = []
    @Published var running: [RunningJob] = []
    @Published var selection: UUID?
    @Published var errorText: String?

    init() { load() }

    private func load() {
        guard let d = try? Data(contentsOf: Paths.historyFile),
              let arr = try? JSONDecoder().decode([Transcript].self, from: d) else { return }
        items = arr.sorted { $0.date > $1.date }
        if ProcessInfo.processInfo.environment["TRANSCRIBE_HISTORY"] != nil { selection = items.first?.id }
    }
    private func save() {
        if let d = try? JSONEncoder().encode(items) { try? d.write(to: Paths.historyFile) }
    }
    func delete(_ id: UUID) {
        items.removeAll { $0.id == id }
        if selection == id { selection = items.first?.id }
        save()
    }

    func addFiles(_ urls: [URL]) {
        var bad: [String] = []
        for u in urls {
            if SUPPORTED.contains(u.pathExtension.lowercased()) { transcribe(u) }
            else { bad.append(u.lastPathComponent) }
        }
        if !bad.isEmpty { errorText = "Unsupported: " + bad.joined(separator: ", ") }
    }

    /// Paste-a-link entry point: download the audio, then transcribe with timestamps.
    func addYouTube(_ urlString: String) {
        let link = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard YouTube.isURL(link) else { errorText = "That doesn't look like a valid URL."; return }
        let job = RunningJob(fileName: "Downloading video…", start: Date())
        running.insert(job, at: 0)
        let jid = job.id
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let (audio, title) = try YouTube.downloadAudio(link)
                DispatchQueue.main.async {
                    self.running.removeAll { $0.id == jid }
                    self.transcribe(audio, displayName: title, sourcePath: link,
                                    cleanupSource: true)
                }
            } catch {
                DispatchQueue.main.async {
                    self.running.removeAll { $0.id == jid }
                    self.errorText = error.localizedDescription
                }
            }
        }
    }

    /// Transcription always produces `[m:ss]`-prefixed, timestamped text. The
    /// output screen can hide the timestamps with a toggle (see DetailPane),
    /// so we keep the full information here and strip it only for display.
    /// - Parameters:
    ///   - displayName: name shown in history (defaults to the file name).
    ///   - sourcePath: value stored for "Reveal/Open" and re-runs (defaults to the file path).
    ///   - cleanupSource: delete the input file (and its temp dir) once converted.
    private func transcribe(_ url: URL, displayName: String? = nil, sourcePath: String? = nil,
                            cleanupSource: Bool = false) {
        let name = displayName ?? url.lastPathComponent
        let source = sourcePath ?? url.path
        let job = RunningJob(fileName: name, start: Date())
        running.insert(job, at: 0)
        let jid = job.id
        DispatchQueue.global(qos: .userInitiated).async {
            let start = Date()
            var text = ""; var ok = false; var errMsg = ""
            do {
                let wav = try AudioConvert.toWav(url)
                defer {
                    try? FileManager.default.removeItem(at: wav)
                    if cleanupSource {
                        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
                    }
                }
                let outStem = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                let p = Process()
                p.executableURL = Paths.whisperBin
                // Always emit SRT so every transcript carries timestamps; the UI
                // decides whether to show them.
                p.arguments = ["-m", Paths.modelBin.path, "-f", wav.path,
                               "-l", "auto", "-t", "\(perfCores())",
                               "-osrt", "-of", outStem.path]
                p.standardOutput = Pipe(); p.standardError = Pipe()
                try p.run(); p.waitUntilExit()
                let out = outStem.appendingPathExtension("srt")
                if let raw = try? String(contentsOf: out, encoding: .utf8) {
                    text = SRT.toTimestamped(raw)
                    try? FileManager.default.removeItem(at: out)
                }
                ok = p.terminationStatus == 0 && !text.isEmpty
                if !ok { errMsg = "whisper exited \(p.terminationStatus)" }
            } catch { ok = false; errMsg = error.localizedDescription }
            let elapsed = Date().timeIntervalSince(start)
            DispatchQueue.main.async {
                self.running.removeAll { $0.id == jid }
                if ok {
                    let t = Transcript(fileName: name, filePath: source,
                                       date: Date(), text: text, seconds: elapsed)
                    self.items.insert(t, at: 0); self.selection = t.id; self.save()
                    // Write a sidecar .txt next to real local files only, matching
                    // the user's current "show timestamps" preference.
                    if !cleanupSource {
                        let side = url.deletingPathExtension().appendingPathExtension("txt")
                        let showStamps = UserDefaults.standard.object(forKey: "showTimestamps") as? Bool ?? true
                        let body = showStamps ? t.text : SRT.stripTimestamps(t.text)
                        try? body.write(to: side, atomically: true, encoding: .utf8)
                    }
                } else {
                    self.errorText = "Could not transcribe \(name).\n\(errMsg)"
                }
            }
        }
    }

    func retranscribe(_ t: Transcript) {
        if YouTube.isURL(t.filePath) { addYouTube(t.filePath); return }
        let u = URL(fileURLWithPath: t.filePath)
        if FileManager.default.fileExists(atPath: u.path) { transcribe(u) }
        else { errorText = "Original file no longer exists:\n\(t.filePath)" }
    }
}

// MARK: - Update check
// Once a day (and on demand) asks GitHub for the latest release and, if it's newer
// than this build, shows a small "Update available" banner. Nothing is sent but a
// plain GET to the public GitHub API; it can be switched off in the app menu.

let RELEASES_API = URL(string: "https://api.github.com/repos/J3012B/Transcribe_Mac/releases/latest")!
let DOWNLOAD_URL = URL(string: "https://github.com/J3012B/Transcribe_Mac/releases/latest/download/Transcribe.dmg")!

final class UpdateChecker: ObservableObject {
    struct Release: Equatable { var version: String; var notesURL: URL }
    @Published var available: Release?
    @Published var lastResult: String?

    static let enabledKey = "autoCheckForUpdates"
    private let lastCheckKey = "lastUpdateCheck"
    private let dismissedKey = "dismissedUpdateVersion"

    var enabled: Bool {
        get { UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Self.enabledKey); objectWillChange.send() }
    }
    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// Automatic check: at most once per day, only if enabled.
    func checkIfDue() {
        guard enabled else { return }
        let last = UserDefaults.standard.double(forKey: lastCheckKey)
        guard Date().timeIntervalSince1970 - last > 86_400 else { return }
        check(userInitiated: false)
    }

    func check(userInitiated: Bool) {
        var req = URLRequest(url: RELEASES_API, timeoutInterval: 15)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("Transcribe/\(Self.currentVersion)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { data, _, _ in
            guard let data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = obj["tag_name"] as? String else {
                DispatchQueue.main.async { if userInitiated { self.lastResult = "Couldn't reach GitHub. Try again later." } }
                return
            }
            let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            let notes = (obj["html_url"] as? String).flatMap(URL.init(string:))
                ?? URL(string: "https://github.com/J3012B/Transcribe_Mac/releases/latest")!
            DispatchQueue.main.async {
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: self.lastCheckKey)
                if Self.isNewer(latest, than: Self.currentVersion) {
                    let dismissed = UserDefaults.standard.string(forKey: self.dismissedKey)
                    if userInitiated || dismissed != latest {
                        self.available = Release(version: latest, notesURL: notes)
                    }
                } else if userInitiated {
                    self.lastResult = "You're up to date (version \(Self.currentVersion))."
                }
            }
        }.resume()
    }

    func dismiss() {
        if let v = available?.version { UserDefaults.standard.set(v, forKey: dismissedKey) }
        available = nil
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}

struct UpdateBanner: View {
    @EnvironmentObject var updates: UpdateChecker
    var body: some View {
        if let r = updates.available {
            HStack(spacing: 10) {
                Image(systemName: "arrow.down.circle.fill").font(.title3).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Transcribe \(r.version) is available").font(.callout).fontWeight(.medium)
                    Button("What's new") { NSWorkspace.shared.open(r.notesURL) }
                        .buttonStyle(.link).font(.caption)
                }
                Spacer()
                Button("Download") { NSWorkspace.shared.open(DOWNLOAD_URL) }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                Button { updates.dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).foregroundStyle(.muted).help("Hide until the next version")
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.10)))
            .padding(.horizontal, 12).padding(.top, 12)
        }
    }
}

// MARK: - App

@main
struct TranscribeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var store = Store()
    @StateObject private var models = ModelManager()
    @StateObject private var tools = ToolsManager()
    @StateObject private var updates = UpdateChecker()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(models)
                .environmentObject(tools)
                .environmentObject(updates)
                .frame(minWidth: 720, minHeight: 460)
                .onAppear {
                    appDelegate.store = store; appDelegate.models = models; appDelegate.flush()
                    updates.checkIfDue()
                }
                .alert(updates.lastResult ?? "",
                       isPresented: Binding(get: { updates.lastResult != nil },
                                            set: { if !$0 { updates.lastResult = nil } })) {
                    Button("OK", role: .cancel) {}
                }
        }
        .defaultSize(width: 900, height: 580)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updates.check(userInitiated: true) }
                Toggle("Automatically Check for Updates", isOn: Binding(
                    get: { updates.enabled }, set: { updates.enabled = $0 }))
            }
            CommandGroup(after: .help) {
                Button("Support Transcribe…") { NSWorkspace.shared.open(DONATE_URL) }
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var store: Store?
    weak var models: ModelManager?
    private var pending: [URL] = []
    func application(_ a: NSApplication, open urls: [URL]) {
        if let s = store, models?.state == .ready { s.addFiles(urls) } else { pending += urls }
    }
    func flush() {
        guard let s = store, models?.state == .ready, !pending.isEmpty else { return }
        s.addFiles(pending); pending.removeAll()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { false }
}

// Higher-contrast replacement for the muted system greys (.secondary/.tertiary).
extension ShapeStyle where Self == Color {
    static var muted: Color { Color.primary.opacity(0.8) }
}

// MARK: - Brand glyph (the mic+waveform from the app icon, as a tintable image)

struct BrandGlyph: View {
    var size: CGFloat
    var body: some View {
        Group {
            if let url = Bundle.main.url(forResource: "MicGlyph", withExtension: "png"),
               let ns = NSImage(contentsOf: url) {
                Image(nsImage: ns).renderingMode(.template).resizable().scaledToFit()
            } else {
                Image(systemName: "waveform").resizable().scaledToFit()
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Root: gate on model readiness

struct RootView: View {
    @EnvironmentObject var models: ModelManager
    var body: some View {
        switch models.state {
        case .ready: ContentView()
        default:     ModelGate()
        }
    }
}

struct ModelGate: View {
    @EnvironmentObject var models: ModelManager
    var body: some View {
        VStack(spacing: 18) {
            BrandGlyph(size: 64).foregroundStyle(.tint)
            Text("Transcribe").font(.largeTitle.bold())
            Text("Fast, private, on-device transcription.\nOne-time setup: download the speech model.")
                .multilineTextAlignment(.center).foregroundStyle(.muted)

            switch models.state {
            case .missing:
                Button {
                    models.startDownload()
                } label: {
                    Label("Download model (~650 MB)", systemImage: "arrow.down.circle")
                        .padding(.horizontal, 8)
                }.controlSize(.large).buttonStyle(.borderedProminent)
            case .downloading(let p):
                VStack(spacing: 8) {
                    ProgressView(value: p).frame(width: 280)
                    Text("Downloading… \(Int(p * 100))%").font(.callout).foregroundStyle(.muted)
                    Text("Runs entirely on your Mac. Nothing is uploaded.")
                        .font(.caption).foregroundStyle(.muted)
                }
            case .failed(let msg):
                VStack(spacing: 8) {
                    Text("Download failed").foregroundStyle(.red)
                    Text(msg).font(.caption).foregroundStyle(.muted)
                        .multilineTextAlignment(.center).frame(maxWidth: 320)
                    Button("Retry") { models.startDownload() }.controlSize(.large)
                }
            case .ready: EmptyView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

// MARK: - Main content (drop + history + detail)

struct ContentView: View {
    @EnvironmentObject var store: Store
    var body: some View {
        HSplitView {
            Sidebar().frame(minWidth: 290, idealWidth: 320, maxWidth: 420)
            DetailPane().frame(minWidth: 380)
        }
        .alert("Something went wrong",
               isPresented: Binding(get: { store.errorText != nil },
                                    set: { if !$0 { store.errorText = nil } })) {
            Button("OK", role: .cancel) { store.errorText = nil }
        } message: { Text(store.errorText ?? "") }
    }
}

struct Sidebar: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var tools: ToolsManager
    @State private var targeted = false
    @State private var showURLSheet = false
    var body: some View {
        VStack(spacing: 0) {
            UpdateBanner()
            DropZone(targeted: $targeted).padding(.horizontal, 12).padding(.top, 12)
            Button { showURLSheet = true } label: {
                Label("Transcribe from a URL…", systemImage: "link")
                    .font(.caption)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.link)
            .padding(.top, 8).padding(.bottom, 10)
            .sheet(isPresented: $showURLSheet) {
                URLSheet().environmentObject(store).environmentObject(tools)
            }
            Divider()
            if store.items.isEmpty && store.running.isEmpty {
                Spacer(); Text("No transcriptions yet").foregroundStyle(.muted).font(.callout); Spacer()
            } else {
                List(selection: $store.selection) {
                    if !store.running.isEmpty {
                        Section("In progress") { ForEach(store.running) { RunningRow(job: $0) } }
                    }
                    Section("History") {
                        ForEach(store.items) { item in
                            HistoryRow(item: item).tag(item.id)
                                .contextMenu { Button("Delete", role: .destructive) { store.delete(item.id) } }
                        }
                    }
                }.listStyle(.sidebar)
            }
            Divider()
            HStack {
                BrandGlyph(size: 12).foregroundStyle(.muted); Text("Whisper · small · offline")
                Spacer()
                Button { NSWorkspace.shared.open(DONATE_URL) } label: {
                    Label("Support", systemImage: "heart.fill")
                }
                .buttonStyle(.link)
                .foregroundStyle(.pink)
                .help("Transcribe is free and open source. Chip in to support it.")
            }.font(.caption).foregroundStyle(.muted).padding(.horizontal, 12).padding(.vertical, 8)
        }.background(.background)
    }
}

struct DropZone: View {
    @EnvironmentObject var store: Store
    @Binding var targeted: Bool
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: targeted ? "tray.and.arrow.down.fill" : "arrow.down.doc")
                .font(.system(size: 30)).foregroundStyle(targeted ? Color.accentColor : .secondary)
            Text("Drop audio or video here").font(.callout).fontWeight(.medium)
            Text("or click to choose files").font(.caption).foregroundStyle(.muted)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 26)
        .background(RoundedRectangle(cornerRadius: 12)
            .fill(targeted ? Color.accentColor.opacity(0.10) : Color.gray.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
            .foregroundStyle(targeted ? Color.accentColor : Color.gray.opacity(0.5)))
        .contentShape(Rectangle())
        .onTapGesture { choose() }
        .onDrop(of: [UTType.fileURL], isTargeted: $targeted) { providers in
            for p in providers {
                p.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    var url: URL?
                    if let d = item as? Data { url = URL(dataRepresentation: d, relativeTo: nil) }
                    else if let u = item as? URL { url = u }
                    if let url { DispatchQueue.main.async { store.addFiles([url]) } }
                }
            }
            return true
        }
    }
    private func choose() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true; panel.canChooseDirectories = false
        panel.allowedContentTypes = [.audio, .movie]; panel.allowsOtherFileTypes = true
        if panel.runModal() == .OK { store.addFiles(panel.urls) }
    }
}

// Secondary feature: paste a link, tools are fetched on first use, then transcribe.
struct URLSheet: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var tools: ToolsManager
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var submitWhenReady = false
    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "link.circle.fill").font(.system(size: 26)).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Transcribe from a URL").font(.headline)
                    Text("Paste a YouTube (or other video) link. The audio is downloaded, then transcribed on your Mac with timestamps.")
                        .font(.caption).foregroundStyle(.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            TextField("https://www.youtube.com/watch?v=…", text: $text)
                .textFieldStyle(.roundedBorder)
                .onSubmit(primaryAction)

            statusRow

            Text("Downloading content may be against a site's terms of service. Use it only for videos you have the right to.")
                .font(.caption2).foregroundStyle(.muted)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                primaryButton
            }
        }
        .padding(20)
        .frame(width: 460)
        .onChange(of: tools.state) { _, newState in
            if newState == .ready, submitWhenReady { submit() }
        }
    }

    @ViewBuilder private var statusRow: some View {
        switch tools.state {
        case .ready:
            EmptyView()
        case .missing:
            Label("First use downloads a few helper tools (~110 MB, one time).",
                  systemImage: "arrow.down.circle")
                .font(.caption).foregroundStyle(.muted)
        case .downloading(let p):
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: p)
                Text("Setting up tools… \(Int(p * 100))%").font(.caption).foregroundStyle(.muted)
            }
        case .failed(let msg):
            Label(msg, systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.red).lineLimit(3)
        }
    }

    @ViewBuilder private var primaryButton: some View {
        switch tools.state {
        case .ready:
            Button("Transcribe") { submit() }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                .disabled(trimmed.isEmpty)
        case .downloading:
            Button("Setting up…") {}.buttonStyle(.borderedProminent).disabled(true)
        case .failed:
            Button("Retry") { primaryAction() }.buttonStyle(.borderedProminent)
        case .missing:
            Button(trimmed.isEmpty ? "Download tools" : "Download & transcribe") { primaryAction() }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
        }
    }

    private func primaryAction() {
        switch tools.state {
        case .ready:
            submit()
        case .missing, .failed:
            submitWhenReady = !trimmed.isEmpty
            tools.startDownload()
        case .downloading:
            break
        }
    }

    private func submit() {
        guard !trimmed.isEmpty else { return }
        store.addYouTube(trimmed)
        dismiss()
    }
}

struct RunningRow: View {
    let job: RunningJob
    var body: some View {
        HStack(spacing: 8) {
            ProgressView().scaleEffect(0.6).frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(job.fileName).lineLimit(1)
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text("Transcribing… \(Int(Date().timeIntervalSince(job.start)))s")
                        .font(.caption).foregroundStyle(.muted)
                }
            }
        }
    }
}

struct HistoryRow: View {
    let item: Transcript
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(item.fileName).lineLimit(1).fontWeight(.medium)
            Text(SRT.stripTimestamps(item.text)).lineLimit(1).font(.caption).foregroundStyle(.muted)
            Text(item.date.formatted(.relative(presentation: .named)))
                .font(.caption2).foregroundStyle(.muted)
        }.padding(.vertical, 2)
    }
}

struct DetailPane: View {
    @EnvironmentObject var store: Store
    @AppStorage("showTimestamps") private var showTimestamps = true
    var current: Transcript? { store.items.first { $0.id == store.selection } }
    /// The text as currently displayed — with or without the `[m:ss]` stamps.
    private func shown(_ t: Transcript) -> String {
        showTimestamps ? t.text : SRT.stripTimestamps(t.text)
    }
    var body: some View {
        if let t = current {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(t.fileName).font(.headline).lineLimit(1)
                        Text("\(t.date.formatted(date: .abbreviated, time: .shortened)) · \(wc(shown(t))) words · \(Int(t.seconds))s")
                            .font(.caption).foregroundStyle(.muted)
                    }
                    Spacer()
                    Toggle(isOn: $showTimestamps) {
                        Label("Timestamps", systemImage: "clock")
                    }
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .help("Show or hide the [m:ss] timestamps in the output.")
                }.padding(16)
                Divider()
                ScrollView {
                    Text(shown(t)).textSelection(.enabled).font(.system(size: 14)).lineSpacing(4)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(16)
                }
            }
            .toolbar {
                ToolbarItemGroup {
                    Button { copy(shown(t)) } label: { Label("Copy", systemImage: "doc.on.doc") }
                    if YouTube.isURL(t.filePath) {
                        Button { open(t.filePath) } label: { Label("Open", systemImage: "safari") }
                    } else {
                        Button { reveal(t.filePath) } label: { Label("Reveal", systemImage: "magnifyingglass") }
                    }
                    Button { store.retranscribe(t) } label: { Label("Re-run", systemImage: "arrow.clockwise") }
                    Button(role: .destructive) { store.delete(t.id) } label: { Label("Delete", systemImage: "trash") }
                }
            }
        } else {
            VStack(spacing: 10) {
                BrandGlyph(size: 52).foregroundStyle(.muted)
                Text("Select a transcription").font(.title3).foregroundStyle(.muted)
                Text("or drop a file on the left to start").font(.callout).foregroundStyle(.muted)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
    private func wc(_ s: String) -> Int { s.split { $0 == " " || $0 == "\n" }.count }
    private func copy(_ s: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s, forType: .string) }
    private func reveal(_ p: String) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)]) }
    private func open(_ p: String) { if let u = URL(string: p) { NSWorkspace.shared.open(u) } }
}
