import Foundation

/// The two admin-protection settings, named as in ManageUsers for Windows.
/// Read through CFPreferences from com.github.manageusers, so a configuration
/// profile wins over /Library/Preferences.
struct AdminGuardSettings {
    static let domainName = "com.github.manageusers"
    static var domain: CFString { domainName as CFString }

    let deleteAdmins: Bool
    let deletableAdmins: [String]

    static func load() -> AdminGuardSettings {
        AdminGuardSettings(
            deleteAdmins: parseBool(CFPreferencesCopyAppValue("DeleteAdmins" as CFString, domain)) ?? false,
            deletableAdmins: parseList(CFPreferencesCopyAppValue("DeletableAdmins" as CFString, domain))
        )
    }

    static func parseBool(_ value: Any?) -> Bool? {
        switch value {
        case let bool as Bool: return bool
        case let number as NSNumber: return number.boolValue
        case let string as String:
            switch string.lowercased() {
            case "1", "true", "yes": return true
            case "0", "false", "no": return false
            default: return nil
            }
        default: return nil
        }
    }

    static func parseList(_ value: Any?) -> [String] {
        switch value {
        case let list as [String]:
            return list.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        case let string as String:
            return string.split(whereSeparator: { $0 == "," || $0 == "\n" })
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        default:
            return []
        }
    }
}
