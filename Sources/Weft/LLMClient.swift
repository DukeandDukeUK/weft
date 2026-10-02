import Foundation

// MARK: - Provider

/// Where sorting runs. The three subscription options shell out to each
/// vendor's own command-line tool, using the login you already have there —
/// never an API key. The two local options talk to a model server on this Mac.
enum Provider: String, CaseIterable, Identifiable, Sendable {
    case claude, codex, gemini, grok, ollama, lmstudio

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: return "Claude (Claude subscription)"
        case .codex: return "ChatGPT (Codex CLI, ChatGPT subscription)"
        case .gemini: return "Gemini (Gemini CLI, Google account)"
        case .grok: return "Grok (Grok CLI, SuperGrok / X subscription)"
        case .ollama: return "Ollama (local)"
        case .lmstudio: return "LM Studio (local)"
        }
    }

    var isLocal: Bool { self == .ollama || self == .lmstudio }

    /// Command-line tool name for subscription providers.
    var executableName: String? {
        switch self {
        case .claude: return "claude"
        case .codex: return "codex"
        case .gemini: return "gemini"
        case .grok: return "grok"
        case .ollama, .lmstudio: return nil
        }
    }

    /// Fallback when no recommendation is available. Empty = the tool's own
    /// default. Normally RecommendationStore supplies the suggestion.
    var defaultModel: String {
        switch self {
        case .claude: return "claude-sonnet-5-5"
        case .codex: return "gpt-6-luna"
        case .grok: return "grok-4.7"
        case .gemini, .ollama, .lmstudio: return ""
        }
    }

    var setupHint: String {
        switch self {
        case .claude: return "Install Claude Code, then run `claude` once in Terminal and sign in."
        case .codex: return "Install the Codex CLI, then run `codex login` in Terminal and sign in with ChatGPT."
        case .gemini: return "Install the Gemini CLI, then run `gemini` once in Terminal and sign in with Google."
        case .grok: return "Install the Grok CLI (version 1.0.13 or later), then run `grok login` in Terminal."
        case .ollama: return "Install Ollama and download a model (e.g. `ollama pull qwen3:8b`)."
        case .lmstudio: return "Install LM Studio, load a model, and start its local server (port 1234)."
        }
    }

    /// API-key variables that would switch the tool to pay-per-token billing.
    /// Removed before every call so the subscription login is always used.
    var keyVariablesToStrip: [String] {
        switch self {
        case .claude: return ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN"]
        case .codex: return ["OPENAI_API_KEY", "CODEX_API_KEY"]
        case .gemini: return ["GEMINI_API_KEY", "GOOGLE_API_KEY", "GOOGLE_GENAI_USE_VERTEXAI"]
        case .grok: return ["XAI_API_KEY", "GROK_API_KEY"]
        case .ollama, .lmstudio: return []
        }
    }

    /// How much transcript to send in one call. Local models have far
    /// smaller context windows than the hosted ones.
    var transcriptCharLimit: Int { isLocal ? 40_000 : 400_000 }

    var localBaseURL: URL? {
        switch self {
        case .ollama: return URL(string: "http://localhost:11434")
        case .lmstudio: return URL(string: "http://localhost:1234")
        default: return nil
        }
    }
}

// MARK: - Detection

/// What's available on this Mac. "Found" means installed / running — whether
/// you're signed in is only known once a call is made (Settings > Test).
struct ProviderStatus: Sendable {
    var found: Bool
    var detail: String
    /// Models a local server reports (empty for subscription tools).
    var localModels: [String] = []
}

enum ProviderDetector {
    static func detect(_ provider: Provider) async -> ProviderStatus {
        if let name = provider.executableName {
            if let path = CommandLocator.find(name) {
                return ProviderStatus(found: true, detail: path)
            }
            return ProviderStatus(found: false, detail: "`\(name)` not found")
        }
        let models = await LocalServer.listModels(provider)
        guard let models else {
            return ProviderStatus(found: false, detail: "not running")
        }
        return ProviderStatus(
            found: !models.isEmpty,
            detail: models.isEmpty ? "running, but no models downloaded" : "\(models.count) model(s)",
            localModels: models
        )
    }

    static func detectAll() async -> [Provider: ProviderStatus] {
        var result: [Provider: ProviderStatus] = [:]
        for provider in Provider.allCases {
            result[provider] = await detect(provider)
        }
        return result
    }
}

/// GUI apps don't inherit your shell's PATH, so look in the usual install
/// spots, then ask a login shell as a last resort.
enum CommandLocator {
    static func find(_ name: String) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.local/bin/\(name)",
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "\(home)/.npm-global/bin/\(name)",
            "\(home)/.bun/bin/\(name)",
            "\(home)/.volta/bin/\(name)",
            "\(home)/.\(name)/bin/\(name)", // e.g. ~/.grok/bin/grok
        ]
        if let hit = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return hit
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = ["-lc", "command -v \(name)"]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = FileHandle.nullDevice
        guard (try? proc.run()) != nil else { return nil }
        proc.waitUntilExit()
        let path = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (proc.terminationStatus == 0 && path.hasPrefix("/")) ? path : nil
    }
}

// MARK: - LLMClient

/// One call to the chosen provider: system instructions + input → reply text.
struct LLMClient: Sendable {
    var provider: Provider
    /// Empty = the provider's default.
    var model: String
    /// Reasoning level where the provider supports one: low, medium, high.
    var effort: String = "medium"

    enum ClientError: Error, LocalizedError {
        case notInstalled(Provider)
        case noLocalModel(Provider)
        case launchFailed(String)
        case failed(Provider, exitCode: Int32, message: String)
        case unreachable(String)
        case httpStatus(Int, String)
        case badPayload(String)
        case timedOut

        var errorDescription: String? {
            switch self {
            case .notInstalled(let p):
                return "Couldn't find the \(p.executableName ?? "") command-line tool. \(p.setupHint)"
            case .noLocalModel(let p):
                return "No model chosen for \(p.displayName). \(p.setupHint)"
            case .launchFailed(let why):
                return "Couldn't start the tool: \(why)"
            case .failed(let p, let code, let message):
                return "\(p.executableName ?? "Tool") exited with code \(code): \(message.isEmpty ? "no error output" : message). If it says you're signed out: \(p.setupHint)"
            case .unreachable(let why):
                return "Couldn't reach the local model server (\(why)). Is it running?"
            case .httpStatus(let code, let body):
                return "Model server returned HTTP \(code): \(body.prefix(300))"
            case .badPayload(let why):
                return "Unexpected reply from the model server: \(why)"
            case .timedOut:
                return "The AI took longer than 10 minutes and was stopped."
            }
        }
    }

    static let timeout: TimeInterval = 600

    var transcriptCharLimit: Int { provider.transcriptCharLimit }

    /// Runs one call and records its token use in the token log.
    func complete(systemPrompt: String, userPrompt: String, purpose: CallPurpose = .other) async throws -> String {
        let reply: String
        let usage: TokenUsage?
        switch provider {
        case .claude, .codex, .gemini, .grok:
            let p = provider, m = model, e = effort
            (reply, usage) = try await Task.detached(priority: .userInitiated) {
                try CLIRunner.run(provider: p, model: m, effort: e, systemPrompt: systemPrompt, input: userPrompt)
            }.value
        case .ollama, .lmstudio:
            guard !model.isEmpty else { throw ClientError.noLocalModel(provider) }
            (reply, usage) = try await LocalServer.complete(provider: provider, model: model, systemPrompt: systemPrompt, userPrompt: userPrompt)
        }
        TokenLog.record(purpose: purpose, provider: provider, model: model, usage: usage)
        return reply
    }

    /// A tiny prompt that should come back as "ok" — proves the tool is
    /// installed AND signed in (or the local server is up with that model).
    func testConnection() async -> Result<String, Error> {
        do {
            let reply = try await complete(systemPrompt: "Reply with exactly: ok", userPrompt: "ping", purpose: .connectionTest)
            let modelLabel = model.isEmpty ? "default model" : model
            return .success("Connected — \(modelLabel) replied \"\(reply.prefix(40))\".")
        } catch {
            return .failure(error)
        }
    }
}

// MARK: - Subscription CLIs

enum CLIRunner {
    /// Returns the reply and, where the tool reports them, its token counts.
    static func run(provider: Provider, model: String, effort: String, systemPrompt: String, input: String) throws -> (String, TokenUsage?) {
        guard let name = provider.executableName, let path = CommandLocator.find(name) else {
            throw LLMClient.ClientError.notInstalled(provider)
        }
        let exe = URL(fileURLWithPath: path)

        // Scratch directory: stdin file, output file, and a neutral working
        // dir so no project instructions get picked up.
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("weft-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let inputURL = work.appendingPathComponent("input.txt")
        let outputURL = work.appendingPathComponent("reply.txt")

        var args: [String]
        var stdinText = input
        switch provider {
        case .claude:
            args = [
                "-p",
                "--system-prompt", systemPrompt,
                "--tools", "",
                "--strict-mcp-config",
                "--setting-sources", "",
                "--no-session-persistence",
                // JSON carries the reply plus its token counts.
                "--output-format", "json",
                "--effort", effort,
            ]
            let m = model.isEmpty ? provider.defaultModel : model
            if !m.isEmpty { args += ["--model", m] }
        case .codex:
            // No separate system-prompt flag: instructions go first in the input.
            stdinText = combined(systemPrompt, input)
            args = [
                "exec",
                "--skip-git-repo-check",
                "--ephemeral",
                "--ignore-user-config",
                "--ignore-rules",
                "-s", "read-only",
                "-C", work.path,
                "-c", "model_reasoning_effort=\(effort)",
                "-o", outputURL.path,
            ]
            if !model.isEmpty { args += ["-m", model] }
            args.append("-")
        case .gemini:
            stdinText = combined(systemPrompt, input)
            args = ["-o", "json"]
            if !model.isEmpty { args += ["-m", model] }
        case .grok:
            args = [
                "--prompt-file", inputURL.path,
                "--system-prompt-override", systemPrompt,
                "--tools", "",
                "--disable-web-search",
                "--no-memory",
                "--no-plan",
                "--no-subagents",
                "--output-format", "plain",
                "--effort", effort,
                "--cwd", work.path,
            ]
            if !model.isEmpty { args += ["-m", model] }
        case .ollama, .lmstudio:
            preconditionFailure("local providers don't use the CLI runner")
        }
        try Data(stdinText.utf8).write(to: inputURL)

        let proc = Process()
        proc.executableURL = exe
        proc.currentDirectoryURL = work
        proc.arguments = args
        var env = ProcessInfo.processInfo.environment
        for key in provider.keyVariablesToStrip { env.removeValue(forKey: key) }
        env["PATH"] = "\(exe.deletingLastPathComponent().path):/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        proc.environment = env
        // Grok reads the prompt from --prompt-file; the others from stdin.
        proc.standardInput = provider == .grok ? FileHandle.nullDevice : try FileHandle(forReadingFrom: inputURL)
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        do {
            try proc.run()
        } catch {
            throw LLMClient.ClientError.launchFailed(error.localizedDescription)
        }

        // Drain both pipes concurrently so a full buffer can't stall the child.
        var outData = Data()
        var errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global().async {
            errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        if group.wait(timeout: .now() + LLMClient.timeout) == .timedOut {
            proc.terminate()
            throw LLMClient.ClientError.timedOut
        }
        proc.waitUntilExit()

        let out = String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let err = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard proc.terminationStatus == 0 else {
            // Tools print the useful part last; keep the message short.
            let message = (err.isEmpty ? out : err).split(separator: "\n").suffix(4).joined(separator: " ")
            throw LLMClient.ClientError.failed(provider, exitCode: proc.terminationStatus, message: message)
        }

        switch provider {
        case .claude:
            return try parseClaude(out)
        case .codex:
            // Codex writes only the final answer to the -o file. It doesn't report token counts.
            let reply = (try? String(contentsOf: outputURL, encoding: .utf8)) ?? out
            return (reply.trimmingCharacters(in: .whitespacesAndNewlines), nil)
        case .gemini:
            // JSON output keeps status lines out of the answer.
            struct GeminiJSON: Decodable { let response: String? }
            if let data = out.data(using: .utf8),
               let decoded = try? JSONDecoder().decode(GeminiJSON.self, from: data),
               let response = decoded.response {
                return (response.trimmingCharacters(in: .whitespacesAndNewlines), geminiUsage(data))
            }
            return (out, nil)
        default:
            return (out, nil)
        }
    }

    /// `claude -p --output-format json`: {"result": "...", "is_error": false,
    /// "usage": {"input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens", "output_tokens"}}.
    private static func parseClaude(_ out: String) throws -> (String, TokenUsage?) {
        struct Usage: Decodable {
            let input_tokens: Int?
            let cache_read_input_tokens: Int?
            let cache_creation_input_tokens: Int?
            let output_tokens: Int?
        }
        struct Reply: Decodable {
            let result: String?
            let is_error: Bool?
            let usage: Usage?
        }
        guard let data = out.data(using: .utf8),
              let reply = try? JSONDecoder().decode(Reply.self, from: data) else {
            // Not JSON (older tool?): treat the whole output as the answer.
            return (out, nil)
        }
        let text = (reply.result ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if reply.is_error == true {
            throw LLMClient.ClientError.failed(.claude, exitCode: 0, message: text)
        }
        let usage = reply.usage.map {
            TokenUsage(
                input: $0.input_tokens ?? 0,
                cachedInput: ($0.cache_read_input_tokens ?? 0) + ($0.cache_creation_input_tokens ?? 0),
                output: $0.output_tokens ?? 0
            )
        }
        return (text, usage)
    }

    /// Gemini CLI JSON: "stats": {"models": {"<model>": {"tokens": {"prompt", "candidates", "cached", ...}}}}.
    /// Read loosely; nil if the shape isn't there.
    private static func geminiUsage(_ data: Data) -> TokenUsage? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let stats = root["stats"] as? [String: Any],
              let models = stats["models"] as? [String: Any], !models.isEmpty else { return nil }
        var total = TokenUsage.zero
        for case let model as [String: Any] in models.values {
            guard let tokens = model["tokens"] as? [String: Any] else { continue }
            let prompt = tokens["prompt"] as? Int ?? 0
            let cached = tokens["cached"] as? Int ?? 0
            total = total + TokenUsage(
                input: max(prompt - cached, 0),
                cachedInput: cached,
                output: (tokens["candidates"] as? Int ?? 0) + (tokens["thoughts"] as? Int ?? 0)
            )
        }
        return total
    }

    private static func combined(_ system: String, _ input: String) -> String {
        "INSTRUCTIONS (follow exactly):\n\(system)\n\nINPUT:\n\(input)"
    }
}

// MARK: - Local model servers

enum LocalServer {
    /// Models the server offers, or nil if it isn't running.
    static func listModels(_ provider: Provider) async -> [String]? {
        guard let base = provider.localBaseURL else { return nil }
        var request: URLRequest
        switch provider {
        case .ollama: request = URLRequest(url: base.appending(path: "api/tags"))
        case .lmstudio: request = URLRequest(url: base.appending(path: "v1/models"))
        default: return nil
        }
        request.timeoutInterval = 2
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            return nil
        }
        switch provider {
        case .ollama:
            struct Tag: Decodable { let name: String }
            struct Tags: Decodable { let models: [Tag] }
            return (try? JSONDecoder().decode(Tags.self, from: data))?.models.map(\.name) ?? []
        default:
            struct Entry: Decodable { let id: String }
            struct List: Decodable { let data: [Entry] }
            return (try? JSONDecoder().decode(List.self, from: data))?.data.map(\.id) ?? []
        }
    }

    static func complete(provider: Provider, model: String, systemPrompt: String, userPrompt: String) async throws -> (String, TokenUsage?) {
        guard let base = provider.localBaseURL else { throw LLMClient.ClientError.badPayload("no server address") }
        let messages = [
            ["role": "system", "content": systemPrompt],
            ["role": "user", "content": userPrompt],
        ]
        var request: URLRequest
        let payload: [String: Any]
        switch provider {
        case .ollama:
            // Native API so the context window can be raised; Ollama's
            // default is too small for a chat transcript.
            request = URLRequest(url: base.appending(path: "api/chat"))
            payload = [
                "model": model,
                "messages": messages,
                "stream": false,
                "options": ["temperature": 0.2, "num_ctx": 16_384],
            ]
        default:
            request = URLRequest(url: base.appending(path: "v1/chat/completions"))
            payload = ["model": model, "messages": messages, "temperature": 0.2]
        }
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = LLMClient.timeout
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw LLMClient.ClientError.unreachable(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw LLMClient.ClientError.badPayload("no HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw LLMClient.ClientError.httpStatus(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        switch provider {
        case .ollama:
            struct Message: Decodable { let content: String }
            struct Reply: Decodable {
                let message: Message
                let prompt_eval_count: Int?
                let eval_count: Int?
            }
            guard let reply = try? JSONDecoder().decode(Reply.self, from: data) else {
                throw LLMClient.ClientError.badPayload("couldn't read Ollama's reply")
            }
            let usage = (reply.prompt_eval_count != nil || reply.eval_count != nil)
                ? TokenUsage(input: reply.prompt_eval_count ?? 0, cachedInput: 0, output: reply.eval_count ?? 0)
                : nil
            return (stripThinking(reply.message.content), usage)
        default:
            struct Message: Decodable { let content: String }
            struct Choice: Decodable { let message: Message }
            struct Usage: Decodable { let prompt_tokens: Int?; let completion_tokens: Int? }
            struct Reply: Decodable { let choices: [Choice]; let usage: Usage? }
            guard let reply = try? JSONDecoder().decode(Reply.self, from: data),
                  let first = reply.choices.first else {
                throw LLMClient.ClientError.badPayload("couldn't read LM Studio's reply")
            }
            let usage = reply.usage.map {
                TokenUsage(input: $0.prompt_tokens ?? 0, cachedInput: 0, output: $0.completion_tokens ?? 0)
            }
            return (stripThinking(first.message.content), usage)
        }
    }

    /// Some local reasoning models wrap their thinking in <think>…</think>
    /// before the answer; keep only the answer.
    static func stripThinking(_ text: String) -> String {
        var t = text
        if let end = t.range(of: "</think>") {
            t = String(t[end.upperBound...])
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
