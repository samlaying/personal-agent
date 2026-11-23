import Foundation
import Observation
import PACore
import SwiftUI

/// App configuration. Model keys live in the login keychain; the rest in UserDefaults.
@MainActor
@Observable
final class AppSettings {
    static let shared = AppSettings()

    private let defaults: UserDefaults
    private static let keychainService = "com.sam.personal-agent"

    private enum Key {
        static let baseURL = "provider.baseURL"
        static let model = "provider.model"
        static let temperature = "provider.temperature"
        static let hotkeyEnabled = "hotkey.enabled"
        static let tavilyAccount = "tavily"
        static let modelAccount = "model-provider"
        static let secondRoute = "answer.route"
        static let secondPreprocess = "answer.preprocessWithMain"
        static let secondBaseURL = "second.baseURL"
        static let secondModel = "second.model"
        static let secondAccount = "second-provider"
    }

    var baseURL: String {
        didSet { defaults.set(baseURL, forKey: Key.baseURL) }
    }

    var model: String {
        didSet { defaults.set(model, forKey: Key.model) }
    }

    var temperature: Double? {
        didSet {
            if let temperature {
                defaults.set(temperature, forKey: Key.temperature)
            } else {
                defaults.removeObject(forKey: Key.temperature)
            }
        }
    }

    var hotkeyEnabled: Bool {
        didSet { defaults.set(hotkeyEnabled, forKey: Key.hotkeyEnabled) }
    }

    /// Which endpoint produces the reply the user sees.
    var answerRoute: AnswerRoute {
        didSet { defaults.set(answerRoute.rawValue, forKey: Key.secondRoute) }
    }

    /// Run the main model over the message first and hand its notes to the second channel.
    var preprocessWithMain: Bool {
        didSet { defaults.set(preprocessWithMain, forKey: Key.secondPreprocess) }
    }

    var secondBaseURL: String {
        didSet { defaults.set(secondBaseURL, forKey: Key.secondBaseURL) }
    }

    var secondModel: String {
        didSet { defaults.set(secondModel, forKey: Key.secondModel) }
    }

    private var secondKey: String {
        didSet { try? KeychainStore.write(secondKey, service: Self.keychainService, account: Key.secondAccount) }
    }

    var hasSecondKey: Bool { !secondKey.isEmpty }

    func applySecondKey(_ newKey: String) {
        secondKey = newKey
    }

    var tavilyKey: String {
        didSet { try? KeychainStore.write(tavilyKey, service: Self.keychainService, account: Key.tavilyAccount) }
    }

    private var modelKey: String {
        didSet { try? KeychainStore.write(modelKey, service: Self.keychainService, account: Key.modelAccount) }
    }

    var isConfigured: Bool {
        switch answerRoute {
        case .agent:
            URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines))?.host != nil && !model.isEmpty
        case .second:
            URL(string: secondBaseURL.trimmingCharacters(in: .whitespacesAndNewlines))?.host != nil
                && !secondModel.isEmpty
        }
    }

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.baseURL = defaults.string(forKey: Key.baseURL) ?? "https://api.openai.com/v1"
        self.model = defaults.string(forKey: Key.model) ?? "gpt-4o-mini"
        self.temperature = defaults.object(forKey: Key.temperature) as? Double
        self.hotkeyEnabled = defaults.object(forKey: Key.hotkeyEnabled) as? Bool ?? true
        self.tavilyKey = (try? KeychainStore.read(service: Self.keychainService, account: Key.tavilyAccount)) ?? ""
        self.modelKey = (try? KeychainStore.read(service: Self.keychainService, account: Key.modelAccount)) ?? ""
        self.answerRoute = AnswerRoute(rawValue: defaults.string(forKey: Key.secondRoute) ?? "") ?? .agent
        self.preprocessWithMain = defaults.object(forKey: Key.secondPreprocess) as? Bool ?? false
        self.secondBaseURL = defaults.string(forKey: Key.secondBaseURL) ?? "http://192.227.138.214:7863/v1"
        self.secondModel = defaults.string(forKey: Key.secondModel) ?? "cn:glm-5.3-flash"
        let storedSecond = (try? KeychainStore.read(service: Self.keychainService, account: Key.secondAccount)) ?? ""
        // First run: take the key from the local agent config once, then keep it in the keychain
        // so later launches do not depend on that file existing.
        if storedSecond.isEmpty {
            let imported = Self.importedSecondKey()
            self.secondKey = imported
            if !imported.isEmpty {
                try? KeychainStore.write(imported, service: Self.keychainService, account: Key.secondAccount)
            }
        } else {
            self.secondKey = storedSecond
        }
    }

    /// Reads `providerApiKeys["local-proxy"]` from ~/.myagents/config.json, if present.
    private static func importedSecondKey() -> String {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".myagents/config.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let keys = root["providerApiKeys"] as? [String: Any],
              let key = keys["local-proxy"] as? String,
              !key.isEmpty
        else { return "" }
        return key
    }

    func applyModelKey(_ newKey: String) {
        modelKey = newKey
    }

    /// Empty fields are not written back, so clearing the field in the UI cannot erase a
    /// key that is merely not echoed back into the secure field.
    var hasModelKey: Bool { !modelKey.isEmpty }

    /// Values the runner needs, copied once per run so tools never touch main-actor state.
    struct Snapshot: Sendable {
        var baseURL: String
        var model: String
        var modelKey: String
        var tavilyKey: String
        var temperature: Double?
        var answerRoute: AnswerRoute
        var preprocessWithMain: Bool
        var secondBaseURL: String
        var secondModel: String
        var secondKey: String
    }

    func snapshot() -> Snapshot {
        Snapshot(
            baseURL: baseURL,
            model: model,
            modelKey: modelKey,
            tavilyKey: tavilyKey,
            temperature: temperature,
            answerRoute: answerRoute,
            preprocessWithMain: preprocessWithMain,
            secondBaseURL: secondBaseURL,
            secondModel: secondModel,
            secondKey: secondKey
        )
    }
}
