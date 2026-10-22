import Foundation
import Security

enum AppCodeSigning {
    /// Reading our own signature does not inspect or request privacy grants.
    static let hasUnstableIdentity: Bool = {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, [], &code) == errSecSuccess,
              let code else { return true }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let dictionary = information as? [String: Any] else { return true }
        let certificates = dictionary[kSecCodeInfoCertificates as String] as? [Any]
        return certificates?.isEmpty ?? true
    }()
}
