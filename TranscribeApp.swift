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

let SUPPORTED: Set<String> = ["m4a","mp3","wav","aiff","aif","caf","flac","mp4","mov",
                              "m4v","aac","3gp","amr","au"]

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
    static var historyFile: URL { support.appendingPathComponent("history.json") }
    // Bundled binary: Contents/Resources/whisper/bin/whisper-cli
    static var whisperBin: URL {
        Bundle.main.resourceURL!.appendingPathComponent("whisper/bin/whisper-cli")
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
    static func toWav(_ input: URL) throws -> URL {
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

    private func transcribe(_ url: URL) {
        let job = RunningJob(fileName: url.lastPathComponent, start: Date())
        running.insert(job, at: 0)
        let jid = job.id
        DispatchQueue.global(qos: .userInitiated).async {
            let start = Date()
            var text = ""; var ok = false; var errMsg = ""
            do {
                let wav = try AudioConvert.toWav(url)
                defer { try? FileManager.default.removeItem(at: wav) }
                let outStem = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                let p = Process()
                p.executableURL = Paths.whisperBin
                p.arguments = ["-m", Paths.modelBin.path, "-f", wav.path,
                               "-l", "auto", "-t", "\(perfCores())",
                               "-otxt", "-of", outStem.path]
                p.standardOutput = Pipe(); p.standardError = Pipe()
                try p.run(); p.waitUntilExit()
                let txt = outStem.appendingPathExtension("txt")
                if let raw = try? String(contentsOf: txt, encoding: .utf8) {
                    text = raw.split(separator: "\n")
                        .map { $0.hasPrefix(" ") ? String($0.dropFirst()) : String($0) }
                        .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                        .joined(separator: "\n")
                    try? FileManager.default.removeItem(at: txt)
                }
                ok = p.terminationStatus == 0 && !text.isEmpty
                if !ok { errMsg = "whisper exited \(p.terminationStatus)" }
            } catch { ok = false; errMsg = error.localizedDescription }
            let elapsed = Date().timeIntervalSince(start)
            DispatchQueue.main.async {
                self.running.removeAll { $0.id == jid }
                if ok {
                    let t = Transcript(fileName: url.lastPathComponent, filePath: url.path,
                                       date: Date(), text: text, seconds: elapsed)
                    self.items.insert(t, at: 0); self.selection = t.id; self.save()
                    let side = url.deletingPathExtension().appendingPathExtension("txt")
                    try? t.text.write(to: side, atomically: true, encoding: .utf8)
                } else {
                    self.errorText = "Could not transcribe \(url.lastPathComponent).\n\(errMsg)"
                }
            }
        }
    }

    func retranscribe(_ t: Transcript) {
        let u = URL(fileURLWithPath: t.filePath)
        if FileManager.default.fileExists(atPath: u.path) { transcribe(u) }
        else { errorText = "Original file no longer exists:\n\(t.filePath)" }
    }
}

// MARK: - App

@main
struct TranscribeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var store = Store()
    @StateObject private var models = ModelManager()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(models)
                .frame(minWidth: 720, minHeight: 460)
                .onAppear { appDelegate.store = store; appDelegate.models = models; appDelegate.flush() }
        }
        .defaultSize(width: 900, height: 580)
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
    @State private var targeted = false
    var body: some View {
        VStack(spacing: 0) {
            DropZone(targeted: $targeted).padding(12)
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
                BrandGlyph(size: 12).foregroundStyle(.muted); Text("Whisper · small")
                Spacer(); Text("local · offline")
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
            Text(item.text).lineLimit(1).font(.caption).foregroundStyle(.muted)
            Text(item.date.formatted(.relative(presentation: .named)))
                .font(.caption2).foregroundStyle(.muted)
        }.padding(.vertical, 2)
    }
}

struct DetailPane: View {
    @EnvironmentObject var store: Store
    var current: Transcript? { store.items.first { $0.id == store.selection } }
    var body: some View {
        if let t = current {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(t.fileName).font(.headline).lineLimit(1)
                        Text("\(t.date.formatted(date: .abbreviated, time: .shortened)) · \(wc(t.text)) words · \(Int(t.seconds))s")
                            .font(.caption).foregroundStyle(.muted)
                    }
                    Spacer()
                }.padding(16)
                Divider()
                ScrollView {
                    Text(t.text).textSelection(.enabled).font(.system(size: 14)).lineSpacing(4)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(16)
                }
            }
            .toolbar {
                ToolbarItemGroup {
                    Button { copy(t.text) } label: { Label("Copy", systemImage: "doc.on.doc") }
                    Button { reveal(t.filePath) } label: { Label("Reveal", systemImage: "magnifyingglass") }
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
}
