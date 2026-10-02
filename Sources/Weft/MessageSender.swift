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
                return "macOS blocked the send: Automation permission is not granted. Open System Settings > Privacy & Security > Automation and allow Weft to control Messages."
            case .launchFailed(let why):
                return "Could not launch the send helper: \(why)"
            case .failed(let code, let message):
                return "Send failed (exit \(code)): \(message)"
            }
        }
    }

    /// Escape text for embedding inside an AppleScript double-quoted string.
    /// Visible for unit testing.
    static func appleScriptEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    static func send(text: String, to handleId: String) throws {
        // No shell is involved (we exec osascript directly), so the only
        // quoting we need is AppleScript's own string-literal escaping.
        let script = """
            tell application "Messages"
                send "\(appleScriptEscape(text))" to buddy "\(appleScriptEscape(handleId))"
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
    static func send(text: String, toChat chatGuid: String, service: String) throws {
        var candidates = [chatGuid]
        if chatGuid.hasPrefix("any;"), !service.isEmpty {
            candidates.append(service + chatGuid.dropFirst(3))
        }
        var lastError = ""
        var lastStatus: Int32 = 0
        for id in candidates {
            let script = """
                tell application "Messages"
                    send "\(appleScriptEscape(text))" to chat id "\(appleScriptEscape(id))"
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
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        do {
            try proc.run()
        } catch {
            throw SendError.launchFailed(error.localizedDescription)
        }
        proc.waitUntilExit()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        let errText = String(data: errData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (proc.terminationStatus, errText)
    }
}
