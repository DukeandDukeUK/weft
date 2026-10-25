import Foundation

// MARK: - MessageSender

/// Sends iMessages by driving the Messages app through AppleScript.
///
/// This sends **as you** — there is no way to impersonate the
/// other side. Requires the Automation permission
/// (System Settings > Privacy & Security > Automation); the first attempt
/// triggers the macOS prompt.
struct MessageSender: Sendable {
    enum SendError: Error, LocalizedError {
        case automationDenied
        case launchFailed(String)
        case failed(exitCode: Int32, message: String)

        var errorDescription: String? {
            switch self {
            case .automationDenied:
                return String(localized: "macOS blocked the send: Automation permission is not granted. Open System Settings > Privacy & Security > Automation and allow Weft to control Messages.")
            case .launchFailed(let why):
                return String(localized: "Could not launch the send helper: \(why)")
            case .failed(let code, let message):
                return String(localized: "Send failed (exit \(Int(code))): \(message)")
            }
        }
    }

    /// Escape text for embedding inside an AppleScript double-quoted string.
    /// Visible for unit testing.
    static func appleScriptEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// What to send: text, or a file (by path).
    enum Payload: Sendable {
        case text(String)
        case file(URL)

        /// The AppleScript expression for it.
        var script: String {
            switch self {
            case .text(let text): return "\"\(MessageSender.appleScriptEscape(text))\""
            case .file(let url): return "POSIX file \"\(MessageSender.appleScriptEscape(url.path))\""
            }
        }
    }

    static func send(text: String, to handleId: String) throws {
        try send(.text(text), to: handleId)
    }

    static func send(text: String, toChat chatGuid: String, service: String) throws {
        try send(.text(text), toChat: chatGuid, service: service)
    }

    /// Tests: messages go here instead of to Messages (nothing is sent).
    nonisolated(unsafe) static var testHook: ((String) -> Void)?

    private static func caughtByTest(_ payload: Payload) -> Bool {
        guard let hook = testHook else { return false }
        switch payload {
        case .text(let text): hook(text)
        case .file(let url): hook("[file] " + url.lastPathComponent)
        }
        return true
    }

    static func send(_ payload: Payload, to handleId: String) throws {
        if caughtByTest(payload) { return }
        // No shell is involved (we exec osascript directly), so the only
        // quoting we need is AppleScript's own string-literal escaping.
        let script = """
            tell application "Messages"
                send \(payload.script) to buddy "\(appleScriptEscape(handleId))"
            end tell
            """
        let (status, errText) = try runOsascript(script: script)
        guard status == 0 else {
            if errText.localizedCaseInsensitiveContains("not authorized") || errText.contains("-1743") {
                throw SendError.automationDenied
            }
            throw SendError.failed(exitCode: status, message: errText)
        }
    }

    /// Send to a whole conversation by Messages' chat id — for group chats,
    /// this reaches everyone in the group (Messages: "send … to chat").
    /// - Parameter service: "iMessage" or "SMS", used only if Messages doesn't
    ///   recognise the database's newer "any;…" id form.
    static func send(_ payload: Payload, toChat chatGuid: String, service: String) throws {
        if caughtByTest(payload) { return }
        var candidates = [chatGuid]
        if chatGuid.hasPrefix("any;"), !service.isEmpty {
            candidates.append(service + chatGuid.dropFirst(3))
        }
        var lastError = ""
        var lastStatus: Int32 = 0
        for id in candidates {
            let script = """
                tell application "Messages"
                    send \(payload.script) to chat id "\(appleScriptEscape(id))"
                end tell
                """
            let (status, errText) = try runOsascript(script: script)
            if status == 0 { return }
            if errText.localizedCaseInsensitiveContains("not authorized") || errText.contains("-1743") {
                throw SendError.automationDenied
            }
            // -1728 = "can't get chat id …": try the next id form. Anything
            // else is a real failure — stop, so nothing is sent twice.
            lastError = errText
            lastStatus = status
            guard errText.contains("-1728") else { break }
        }
        throw SendError.failed(exitCode: lastStatus, message: lastError)
    }

    // MARK: - Files

    /// Messages only reliably reads files it's asked to send by script from
    /// certain folders (its own sandbox), so each file is copied into
    /// ~/Pictures/Weft just before sending. The copies are cleared out after
    /// a day (Messages keeps its own copy once sent).
    static var stagingFolder: URL {
        stagingOverride ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Pictures/Weft")
    }
    /// Tests stage files in a scratch folder instead.
    nonisolated(unsafe) static var stagingOverride: URL?

    static func stage(_ file: URL) throws -> URL {
        let folder = stagingFolder.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let copy = folder.appending(path: file.lastPathComponent)
        try FileManager.default.copyItem(at: file, to: copy)
        return copy
    }

    /// Remove staged copies older than a day.
    static func clearOldStagedFiles(olderThan age: TimeInterval = 86_400) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: stagingFolder, includingPropertiesForKeys: [.creationDateKey]) else { return }
        for item in items {
            let created = (try? item.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            if Date().timeIntervalSince(created) > age { try? fm.removeItem(at: item) }
        }
    }

    /// Best-effort check: can we currently drive Messages via Apple Events?
    /// Note the first call triggers the system permission prompt.
    static func automationAvailable() -> Bool {
        do {
            let (status, _) = try runOsascript(script: "tell application \"Messages\" to get version")
            return status == 0
        } catch {
            return false
        }
    }

    // MARK: - Private

    private static func runOsascript(script: String) throws -> (Int32, String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript", isDirectory: false)
        proc.arguments = ["-e", script]
        // Only the error text is used. Read it to the end BEFORE waiting for
        // exit: reading afterwards would deadlock if the output ever
        // outgrew the pipe. Nothing reads stdout, so it goes nowhere rather
        // than into a pipe that could fill up.
        let errPipe = Pipe()
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = errPipe
        do {
            try proc.run()
        } catch {
            throw SendError.launchFailed(error.localizedDescription)
        }
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        let errText = String(data: errData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (proc.terminationStatus, errText)
    }
}
