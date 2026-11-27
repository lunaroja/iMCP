import Foundation
import Security
import XPC

enum ManagedHome {
    static let servicePath = "Contents/Helpers/iMCP Home.app"
    static let hostKey = "iMCPHomeHostIdentifier"

    static func agentPlist(for host: String) -> String { "\(host).home-helper.plist" }
    static func machService(for host: String) -> String { "\(host).home-xpc" }
    static let toolKey = "tool"
    static let argumentsKey = "arguments"
    static let valueKey = "value"
    static let errorKey = "error"
    static let readyTool = "imcp/home/ready"

    static func service(in app: URL) -> Bundle? {
        Bundle(url: app.appendingPathComponent(servicePath))
    }

    static func data(in message: xpc_object_t, key: String) -> Data? {
        var length = 0
        guard let bytes = xpc_dictionary_get_data(message, key, &length) else { return nil }
        return Data(bytes: bytes, count: length)
    }

    static func setData(_ data: Data, in message: xpc_object_t, key: String) {
        data.withUnsafeBytes { buffer in
            if let base = buffer.baseAddress {
                xpc_dictionary_set_data(message, key, base, buffer.count)
            }
        }
    }

    /// Both peers require an Apple-issued signature from their own team and the expected signing ID.
    static func peerRequirement(identifier: String) throws -> String {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var signingInfo: CFDictionary?
        let teamCharacters = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ"
        let identifierCharacters = CharacterSet(charactersIn: teamCharacters + "abcdefghijklmnopqrstuvwxyz._-")
        guard !identifier.isEmpty, identifier.unicodeScalars.allSatisfy(identifierCharacters.contains),
            SecCodeCopySelf([], &code) == errSecSuccess, let code,
            SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
            SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &signingInfo)
                == errSecSuccess,
            let info = signingInfo as? [String: Any],
            let team = info[kSecCodeInfoTeamIdentifier as String] as? String,
            team.count == 10, team.allSatisfy(teamCharacters.contains)
        else {
            throw HomeError("The bundled HomeKit service requires an iMCP build signed by an Apple Developer team.")
        }
        return "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\(team)\""
    }
}
