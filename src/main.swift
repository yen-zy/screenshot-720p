import AppKit
import CoreServices
import Foundation

final class ConverterDelegate: NSObject, NSApplicationDelegate {
    private var stream: FSEventStreamRef?
    private var worker: Process?
    private var scheduled: DispatchWorkItem?
    private var scheduledAt: Date?
    private var needsRescan = false
    private var stopping = false
    private var signalSource: DispatchSourceSignal?
    private var wakeObserver: NSObjectProtocol?
    private let folder: URL
    private let state: URL
    private let panel = ProgressPanel(shareable: CommandLine.arguments.contains("--shareable-panel"))
    private let notifier = Notifier()
    private var outputBuffer = Data()
    private let videoExtensions: Set<String> = ["mov", "mp4", "m4v", "mkv", "avi", "webm", "mpg",
        "mpeg", "mts", "m2ts", "ts", "3gp", "3g2", "mxf", "flv", "wmv", "vob", "ogv"]

    override init() {
        let args = CommandLine.arguments
        func option(_ name: String, fallback: String) -> String {
            guard let index = args.firstIndex(of: name), index + 1 < args.count else { return fallback }
            return args[index + 1]
        }
        folder = URL(fileURLWithPath: option("--folder", fallback: "/Users/yen/Documents/Screenshot")).standardizedFileURL
        state = URL(fileURLWithPath: option("--state-dir", fallback:
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Screenshot720p").path))
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        notifier.requestAuthorization()
        signal(SIGTERM, SIG_IGN)
        signalSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        signalSource?.setEventHandler { [weak self] in self?.shutdown(); NSApp.terminate(nil) }
        signalSource?.resume()
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                self?.scheduleScan(after: 0.5)
            }
        do {
            try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
            // Let macOS enforce this app's existing folder-access permission.
            _ = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            try startStream()
            scheduleScan(after: 0)
        } catch {
            report(error)
            NSApp.terminate(nil)
        }
    }

    private func startStream() throws {
        var context = FSEventStreamContext(version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, pointer, count, rawPaths, flags, _ in
            guard let pointer else { return }
            let owner = Unmanaged<ConverterDelegate>.fromOpaque(pointer).takeUnretainedValue()
            let paths = unsafeBitCast(rawPaths, to: NSArray.self) as! [String]
            owner.received(paths: Array(paths.prefix(count)), flags: Array(UnsafeBufferPointer(start: flags, count: count)))
        }
        let options = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes |
            kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagNoDefer)
        guard let created = FSEventStreamCreate(kCFAllocatorDefault, callback, &context,
            [folder.path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.2, options) else {
            throw NSError(domain: "Screenshot720p", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Could not create folder-change listener"])
        }
        stream = created
        FSEventStreamSetDispatchQueue(created, .main)
        guard FSEventStreamStart(created) else {
            throw NSError(domain: "Screenshot720p", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Could not start folder-change listener"])
        }
    }

    private func received(paths: [String], flags: [FSEventStreamEventFlags]) {
        let recoveryFlags = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs |
            kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged)
        for (path, flag) in zip(paths, flags) {
            let url = URL(fileURLWithPath: path).standardizedFileURL
            let isVideo = url.deletingLastPathComponent().path == folder.path &&
                !url.lastPathComponent.hasPrefix(".") && videoExtensions.contains(url.pathExtension.lowercased())
            if flag & recoveryFlags != 0 || url.path == folder.path || isVideo {
                scheduleScan(after: 0.35)
                return
            }
        }
    }

    private func scheduleScan(after seconds: TimeInterval) {
        guard !stopping else { return }
        if worker != nil { needsRescan = true; return }
        let when = Date().addingTimeInterval(max(0, seconds))
        if let existing = scheduledAt, existing <= when { return }
        scheduled?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.runWorker() }
        scheduled = work
        scheduledAt = when
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, seconds), execute: work)
    }

    private func runWorker() {
        scheduled = nil
        scheduledAt = nil
        guard !stopping, worker == nil else { return }
        needsRescan = false
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/Library/Frameworks/Python.framework/Versions/3.13/bin/python3")
        process.arguments = [Bundle.main.resourceURL!.appendingPathComponent("screenshot_720p.py").path,
            "--folder", folder.path, "--state-dir", state.path, "--settle-seconds", "2"]
        process.qualityOfService = .utility
        let output = Pipe()
        outputBuffer.removeAll()
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            DispatchQueue.main.async { self?.received(output: data) }
        }
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] finished in
            DispatchQueue.main.async { self?.workerFinished(status: finished.terminationStatus) }
        }
        worker = process
        do {
            try process.run()
        } catch {
            worker = nil
            report(error)
            scheduleScan(after: 60)
        }
    }

    /// Worker stdout carries one JSON event per line; empty data means it closed.
    private func received(output data: Data) {
        if data.isEmpty {
            if panel.active { panel.abort() }
            outputBuffer.removeAll()
            return
        }
        outputBuffer.append(data)
        while let newline = outputBuffer.firstIndex(of: 0x0A) {
            let line = outputBuffer[outputBuffer.startIndex..<newline]
            outputBuffer.removeSubrange(outputBuffer.startIndex...newline)
            if let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                handle(event: event)
            }
        }
    }

    private func handle(event: [String: Any]) {
        let file = event["file"] as? String ?? "video"
        let waiting = event["waiting"] as? Int ?? 0
        switch event["event"] as? String {
        case "start":
            panel.start(file: file, source: folder.appendingPathComponent(file), waiting: waiting,
                        hasDuration: event["duration"] is Double)
            if event["quiet"] as? Bool != true { notifier.converting(file: file) }
        case "progress":
            if let percent = event["percent"] as? Double { panel.update(percent: percent) }
        case "done":
            let inSize = (event["size"] as? NSNumber)?.int64Value ?? 0
            let outSize = (event["output_size"] as? NSNumber)?.int64Value ?? 0
            let output = event["output"] as? String ?? ""
            notifier.ready(file: file, output: output, inSize: inSize, outSize: outSize)
            panel.finish(success: true, waiting: waiting, output: output, inSize: inSize, outSize: outSize)
        case "failed":
            notifier.failed(file: file, error: event["error"] as? String ?? "Unknown error")
            panel.finish(success: false, waiting: waiting)
        case "retry_failed":
            panel.finish(success: false, waiting: waiting)
        default:
            break
        }
    }

    private func workerFinished(status: Int32) {
        worker = nil
        guard !stopping else { return }
        if status != 0 {
            scheduleScan(after: needsRescan ? 0.35 : 30)
            return
        }
        try? FileManager.default.removeItem(at: state.appendingPathComponent("access-error.txt"))
        if needsRescan { scheduleScan(after: 0.35); return }
        if let data = try? Data(contentsOf: state.appendingPathComponent("state.json")),
           let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let due = info["next_check_at"] as? Double {
            // Recheck only a file still saving or awaiting retry; idle folders have no timer.
            scheduleScan(after: max(0.1, due - Date().timeIntervalSince1970))
        }
    }

    private func report(_ error: Error) {
        let message = "\(Date()): \(error)\nIf access was denied, allow Screenshot 720p Converter access to Documents in System Settings > Privacy & Security > Files & Folders.\n"
        try? message.write(to: state.appendingPathComponent("access-error.txt"), atomically: true, encoding: .utf8)
    }

    private func shutdown() {
        guard !stopping else { return }
        stopping = true
        scheduled?.cancel()
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
        if let worker, worker.isRunning { worker.terminate(); worker.waitUntilExit() }
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
    }

    func applicationWillTerminate(_ notification: Notification) { shutdown() }
}

let app = NSApplication.shared
let delegate = ConverterDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
