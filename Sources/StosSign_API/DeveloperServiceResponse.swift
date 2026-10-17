import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct DeveloperServiceResponseError: LocalizedError {
    public let statusCode: Int
    public let appleCode: String?
    public let title: String
    public let detail: String?

    public var errorDescription: String? {
        var message = "Apple Developer Services: HTTP \(statusCode)"
        if let appleCode { message += " (\(appleCode))" }
        message += "\n\(title)"
        if let detail, !detail.isEmpty, detail != title { message += "\n\(detail)" }
        return message
    }
}

extension AppleAPI {
    static func decodeCapabilityServiceResponse(_ data: Data, response: HTTPURLResponse) throws -> [String: Any] {
        let dictionary = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if let error = (dictionary?["errors"] as? [[String: Any]])?.first {
            throw DeveloperServiceResponseError(
                statusCode: Int(error["status"] as? String ?? "") ?? response.statusCode,
                appleCode: error["code"] as? String,
                title: error["title"] as? String ?? "Apple rejected the capability request.",
                detail: error["detail"] as? String)
        }
        guard (200...299).contains(response.statusCode) else {
            throw DeveloperServiceResponseError(
                statusCode: response.statusCode, appleCode: nil,
                title: dictionary?["error"] as? String ?? HTTPURLResponse.localizedString(forStatusCode: response.statusCode),
                detail: "The capability update was not accepted. Response type: \(response.mimeType ?? "unknown").")
        }
        // A 204 acknowledges the update without a JSON resource. Do not try to decode it.
        if response.statusCode == 204 && data.isEmpty {
            return ["_capabilityNoContent": true]
        }
        guard let dictionary else {
            throw DeveloperServiceResponseError(
                statusCode: response.statusCode, appleCode: nil,
                title: "Apple returned an unexpected capability response.",
                detail: "Response type: \(response.mimeType ?? "unknown"); bytes: \(data.count). The update could not be confirmed.")
        }
        guard dictionary["data"] is [String: Any] else {
            throw DeveloperServiceResponseError(
                statusCode: response.statusCode, appleCode: nil,
                title: dictionary["error"] as? String ?? "Apple's capability response did not contain a bundle ID resource.",
                detail: "The update could not be confirmed. This is not proof that the installed profile contains the entitlement.")
        }
        return dictionary
    }
}
