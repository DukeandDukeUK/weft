import Contacts
import Foundation

// MARK: - ContactNames

/// Looks up contact names for phone numbers / emails so the conversation
/// picker and title can show "Name (+1 555…)". Asks for Contacts access
/// once; if refused, Weft simply shows the numbers.
@MainActor @Observable
final class ContactNames {
    static let shared = ContactNames()

    private(set) var names: [String: String] = [:]
    private var loaded = false

    /// Ask for access (first time only) and load the address book.
    func load() async {
        guard !loaded else { return }
        loaded = true
        let store = CNContactStore()
        let status = CNContactStore.authorizationStatus(for: .contacts)
        if status == .notDetermined {
            let granted = (try? await store.requestAccess(for: .contacts)) ?? false
            guard granted else { return }
        } else if status != .authorized {
            return
        }
        names = await Task.detached { Self.readAll(store) }.value
    }

    /// Name for one handle, or nil.
    func name(for handle: String) -> String? {
        names[Self.key(handle)]
    }

    /// "Name (+1 555…)" for each participant; just the handle when unknown.
    func display(_ participants: String) -> String {
        let handles = participants.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard !handles.isEmpty else { return participants }
        return handles.map { handle in
            name(for: handle).map { "\($0) (\(handle))" } ?? handle
        }.joined(separator: ", ")
    }

    /// Just the names (falls back to handles) — for compact titles.
    func shortDisplay(_ participants: String) -> String {
        let handles = participants.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        return handles.map { name(for: $0) ?? $0 }.joined(separator: ", ")
    }

    /// Phone numbers match on their last 10 digits (ignores +1, spaces,
    /// dashes); emails match case-insensitively.
    nonisolated static func key(_ handle: String) -> String {
        if handle.contains("@") { return handle.lowercased() }
        let digits = handle.filter(\.isNumber)
        return String(digits.suffix(10))
    }

    nonisolated private static func readAll(_ store: CNContactStore) -> [String: String] {
        let keys: [CNKeyDescriptor] = [
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
        ]
        var result: [String: String] = [:]
        let request = CNContactFetchRequest(keysToFetch: keys)
        try? store.enumerateContacts(with: request) { contact, _ in
            let full = CNContactFormatter.string(from: contact, style: .fullName) ?? ""
            let name = full.isEmpty ? contact.organizationName : full
            guard !name.isEmpty else { return }
            for phone in contact.phoneNumbers {
                let k = key(phone.value.stringValue)
                if !k.isEmpty, result[k] == nil { result[k] = name }
            }
            for email in contact.emailAddresses {
                let k = (email.value as String).lowercased()
                if result[k] == nil { result[k] = name }
            }
        }
        return result
    }
}
