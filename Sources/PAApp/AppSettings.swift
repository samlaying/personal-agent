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

    var tavilyKey: String {
        didSet { try? KeychainStore.write(tavilyKey, service: Self.keychainService, account: Key.tavilyAccount) }
    }

    private var modelKey: String {
        didSet { try? KeychainStore.write(modelKey, service: Self.keychainService, account: Key.modelAccount) }
    }

    var isConfigured: Bool {
        URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines))?.host != nil && !model.isEmpty
    }

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.baseURL = defaults.string(forKey: Key.baseURL) ?? "https://api.openai.com/v1"
        self.model = defaults.string(forKey: Key.model) ?? "gpt-4o-mini"
        self.temperature = defaults.object(forKey: Key.temperature) as? Double
        self.hotkeyEnabled = defaults.object(forKey: Key.hotkeyEnabled) as? Bool ?? true
        self.tavilyKey = (try? KeychainStore.read(service: Self.keychainService, account: Key.tavilyAccount)) ?? ""
        self.modelKey = (try? KeychainStore.read(service: Self.keychainService, account: Key.modelAccount)) ?? ""
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
    }

    func snapshot() -> Snapshot {
        Snapshot(
            baseURL: baseURL,
            model: model,
            modelKey: modelKey,
            tavilyKey: tavilyKey,
            temperature: temperature
        )
    }
}
