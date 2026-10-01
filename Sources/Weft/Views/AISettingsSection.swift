import SwiftUI

// MARK: - AISettingsSection

/// Settings > "Sorting": choose which AI sorts the conversation, see what's
/// installed, test it, and — for people with no AI subscription — set up a
/// free local model in a couple of clicks.
struct AISettingsSection: View {
    @Bindable var viewModel: WeftViewModel
    @Environment(\.openURL) private var openURL

    @State private var statuses: [Provider: ProviderStatus] = [:]
    @State private var isDetecting = false
    @State private var testResult: String?
    @State private var isTesting = false
    @State private var modelDraft = ""
    @State private var pull = OllamaPull()
    @State private var options: [ModelCatalog.Option] = []
    @State private var typingOther = false
    private var store: RecommendationStore { RecommendationStore.shared }

    private var settings: AppSettings { viewModel.settings }

    var body: some View {
        Section("Sorting") {
            Picker("AI", selection: Binding(
                get: { settings.provider },
                set: { newValue in
                    settings.provider = newValue
                    testResult = nil
                    typingOther = false
                    modelDraft = newValue.map { settings.model(for: $0) } ?? ""
                    Task { await loadOptions() }
                }
            )) {
                Text("Choose…").tag(Provider?.none)
                ForEach(Provider.allCases) { provider in
                    Text(label(for: provider)).tag(Provider?.some(provider))
                }
            }

            HStack {
                Button(isDetecting ? "Checking…" : "Check what's installed") {
                    Task { await detect() }
                }
                .disabled(isDetecting)
                Spacer()
            }

            if let provider = settings.provider {
                providerDetail(provider)
            } else {
                Text("Pick the AI you already pay for. No subscription? Choose **Ollama (local)** — it's free and runs on this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .task {
            modelDraft = settings.provider.map { settings.model(for: $0) } ?? ""
            await detect()
            await store.refresh()
            await loadOptions()
        }
    }

    // MARK: - Per-provider detail

    @ViewBuilder
    private func providerDetail(_ provider: Provider) -> some View {
        let status = statuses[provider]

        if let status, !status.found {
            notFound(provider, status: status)
        } else {
            modelRow(provider, status: status)
            testRow(provider)
        }

        Text(privacyNote(provider))
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    /// Menu of the models this provider offers, recommended one first and
    /// marked; "Other…" lets you type any model name.
    @ViewBuilder
    private func modelRow(_ provider: Provider, status: ProviderStatus?) -> some View {
        let recommended = store.recommendedModel(for: provider)
        let selected = settings.effectiveModel(for: provider)
        let ordered = options.filter { $0.id == recommended } + options.filter { $0.id != recommended }

        Picker("Model", selection: Binding(
            get: { typingOther ? "__other__" : (ordered.contains { $0.id == selected } || selected.isEmpty ? selected : "__other__") },
            set: { value in
                testResult = nil
                if value == "__other__" {
                    typingOther = true
                    modelDraft = settings.model(for: provider)
                } else {
                    typingOther = false
                    settings.setModel(value, for: provider)
                }
            }
        )) {
            if recommended.isEmpty {
                Text("Default (the tool chooses) — Recommended").tag("")
            }
            ForEach(ordered) { option in
                Text(option.id == recommended ? "\(option.label) — Recommended" : option.label).tag(option.id)
            }
            Divider()
            Text("Other…").tag("__other__")
        }

        if typingOther || (!selected.isEmpty && !ordered.contains { $0.id == selected }) {
            TextField("Model name", text: $modelDraft, prompt: Text("Exact model name"))
                .onSubmit { settings.setModel(modelDraft, for: provider) }
                .onChange(of: modelDraft) { _, value in settings.setModel(value, for: provider) }
        }

        if let note = store.current.entry(provider)?.note {
            Text(note).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func loadOptions() async {
        guard let provider = settings.provider else { options = []; return }
        options = await ModelCatalog.options(for: provider, status: statuses[provider], recommendations: store.current)
    }

    private func testRow(_ provider: Provider) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button("Test") {
                    isTesting = true
                    testResult = nil
                    Task {
                        guard let client = settings.makeClient() else { isTesting = false; return }
                        let result = await client.testConnection()
                        isTesting = false
                        switch result {
                        case .success(let message): testResult = "✓ " + message
                        case .failure(let error): testResult = "✗ " + error.localizedDescription
                        }
                    }
                }
                .disabled(isTesting)
                if isTesting { ProgressView().scaleEffect(0.7) }
            }
            if let testResult {
                Text(testResult)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    @ViewBuilder
    private func notFound(_ provider: Provider, status: ProviderStatus) -> some View {
        if provider == .ollama {
            ollamaSetup(status: status)
        } else {
            Text("Not found on this Mac (\(status.detail)). \(provider.setupHint)")
                .font(.callout)
        }
    }

    // MARK: - Free local setup (Ollama)

    @ViewBuilder
    private func ollamaSetup(status: ProviderStatus) -> some View {
        let tier = store.current.recommendedLocalModel()
        let recommended = (name: tier?.model ?? "qwen3:4b", size: tier?.size ?? "2.5 GB")
        if status.detail == "not running" {
            VStack(alignment: .leading, spacing: 8) {
                Text("**Free option, private to this Mac.** Two steps:")
                Text("1. Download and open Ollama (a free app that runs AI models on your Mac).")
                Button("Get Ollama") { openURL(URL(string: "https://ollama.com/download")!) }
                Text("2. Come back here and click **Check what's installed**.")
            }
            .font(.callout)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("Ollama is running. Download the recommended model for this Mac: **\(recommended.name)** (about \(recommended.size)).")
                    .font(.callout)
                if pull.isRunning {
                    ProgressView(value: pull.fraction) {
                        Text(pull.status).font(.caption)
                    }
                } else {
                    Button("Download \(recommended.name)") {
                        Task {
                            await pull.run(model: recommended.name)
                            if pull.error == nil {
                                settings.setModel(recommended.name, for: .ollama)
                                await detect()
                            }
                        }
                    }
                }
                if let error = pull.error {
                    Text("✗ " + error).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        Text("Local models are free and private but sort noticeably less well than the subscription AIs, and handle a shorter stretch of the conversation at a time.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    // MARK: - Helpers

    private func detect() async {
        isDetecting = true
        statuses = await ProviderDetector.detectAll()
        isDetecting = false
        await loadOptions()
        // A local provider with one model downloaded and none chosen: use it.
        if let provider = settings.provider, provider.isLocal, settings.model(for: provider).isEmpty,
           let first = statuses[provider]?.localModels.first {
            settings.setModel(first, for: provider)
        }
    }

    private func label(for provider: Provider) -> String {
        guard let status = statuses[provider] else { return provider.displayName }
        return provider.displayName + (status.found ? " — found" : " — not set up")
    }

    private func privacyNote(_ provider: Provider) -> String {
        switch provider {
        case .claude: return "Conversation text is sent to Anthropic for sorting and counts against your Claude plan's usage. No API key is used."
        case .codex: return "Conversation text is sent to OpenAI for sorting and counts against your ChatGPT plan's usage. No API key is used."
        case .gemini: return "Conversation text is sent to Google for sorting, using your Google account's Gemini CLI allowance. No API key is used."
        case .grok: return "Conversation text is sent to xAI for sorting and counts against your Grok plan's usage. No API key is used."
        case .ollama, .lmstudio: return "Everything stays on this Mac."
        }
    }
}

// MARK: - OllamaPull

/// Downloads a model through Ollama's own API, with progress.
@MainActor @Observable
final class OllamaPull {
    var isRunning = false
    var fraction: Double = 0
    var status = ""
    var error: String?

    func run(model: String) async {
        isRunning = true
        fraction = 0
        status = "Starting download…"
        error = nil
        defer { isRunning = false }

        var request = URLRequest(url: URL(string: "http://localhost:11434/api/pull")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 3600
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["model": model, "stream": true])

        struct Progress: Decodable {
            let status: String?
            let total: Int64?
            let completed: Int64?
            let error: String?
        }
        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                error = "Ollama refused the download."
                return
            }
            for try await line in bytes.lines {
                guard let data = line.data(using: .utf8),
                      let p = try? JSONDecoder().decode(Progress.self, from: data) else { continue }
                if let e = p.error { error = e; return }
                if let s = p.status { status = s }
                if let total = p.total, total > 0, let done = p.completed {
                    fraction = Double(done) / Double(total)
                }
            }
            status = "Done"
            fraction = 1
        } catch {
            self.error = "Download failed: \(error.localizedDescription)"
        }
    }
}
