import Foundation
import XCTest
@testable import StosSign_API
import StosSign_Common

final class CapabilityUpdateTests: XCTestCase {
    private func response(_ status: Int, type: String = "application/vnd.api+json") -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://developerservices2.apple.com/services/v1/bundleIds/TESTID")!, statusCode: status,
                        httpVersion: nil, headerFields: ["Content-Type": type])!
    }

    func testJSONAPIErrorsKeepAppleStatusCodeAndDetail() throws {
        let data = try JSONSerialization.data(withJSONObject: ["errors": [["status": "409", "code": "ENTITY_ERROR.INVALID_CAPABILITY", "title": "Capability unavailable", "detail": "This team cannot enable this capability."]]])
        for status in [200, 409] {
            XCTAssertThrowsError(try AppleAPI.decodeCapabilityServiceResponse(data, response: response(status))) { error in
                let error = error as? DeveloperServiceResponseError
                XCTAssertEqual(error?.statusCode, 409)
                XCTAssertEqual(error?.appleCode, "ENTITY_ERROR.INVALID_CAPABILITY")
                XCTAssertEqual(error?.detail, "This team cannot enable this capability.")
            }
        }
    }

    func testHTMLRejectionDoesNotDumpBodyOrBecomeSuccess() {
        XCTAssertThrowsError(try AppleAPI.decodeCapabilityServiceResponse(Data("<html>private-body</html>".utf8), response: response(403, type: "text/html"))) { error in
            XCTAssertTrue(error.localizedDescription.contains("403"))
            XCTAssertFalse(error.localizedDescription.contains("private-body"))
        }
    }

    func test204AcknowledgementAndEmpty200AreDifferent() throws {
        let result = try AppleAPI.decodeCapabilityServiceResponse(Data(), response: response(204))
        XCTAssertEqual(result["_capabilityNoContent"] as? Bool, true)
        XCTAssertThrowsError(try AppleAPI.decodeCapabilityServiceResponse(Data(), response: response(200)))
        XCTAssertThrowsError(try AppleAPI.decodeCapabilityServiceResponse(Data("{}".utf8), response: response(200)))
    }

    func testMalformedJSONAndMissingResourceAreUnconfirmed() {
        for body in ["not-json", "{\"errors\":[]}", "{\"data\":null}"] {
            XCTAssertThrowsError(try AppleAPI.decodeCapabilityServiceResponse(Data(body.utf8), response: response(200)))
        }
    }

    func testFullCapabilityRequestWith200And204() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CapabilityMockProtocol.self]
        let network = URLSession(configuration: configuration)
        defer { network.invalidateAndCancel(); CapabilityMockProtocol.handler = nil }
        let account = try JSONDecoder().decode(Account.self, from: Data("{\"email\":\"test@example.invalid\",\"personId\":1}".utf8))
        let team = Team(name: "Test", identifier: "TESTTEAM", type: .free, account: account)
        let appID = AppID(name: "LiveContainer", identifier: "TESTID", bundleIdentifier: "com.test.LiveContainer", expirationDate: nil, features: [:])
        let anisette = AnisetteData(machineID: "test", oneTimePassword: "fresh-otp", localUserID: "test", routingInfo: 0,
                                    deviceUniqueIdentifier: "test", deviceSerialNumber: "0", deviceDescription: "test",
                                    date: Date(), locale: .current, timeZone: .current)
        let session = AppleAPISession(dsid: "test", authToken: "test", anisetteData: anisette)
        for status in [200, 204] {
            CapabilityMockProtocol.handler = { request in
                XCTAssertEqual(request.httpMethod, "PATCH")
                XCTAssertEqual(request.url?.path, "/services/v1/bundleIds/TESTID")
                XCTAssertNil(request.url?.query)
                XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/vnd.api+json")
                XCTAssertEqual(request.value(forHTTPHeaderField: "X-Apple-I-MD"), "fresh-otp")
                let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: Self.requestBody(request)) as? [String: Any])
                let resource = try XCTUnwrap(body["data"] as? [String: Any])
                XCTAssertEqual(resource["id"] as? String, "TESTID")
                let attributes = try XCTUnwrap(resource["attributes"] as? [String: Any])
                XCTAssertEqual(attributes["identifier"] as? String, "com.test.LiveContainer")
                XCTAssertEqual(attributes["teamId"] as? String, "TESTTEAM")
                let relationships = try XCTUnwrap(resource["relationships"] as? [String: Any])
                let capabilities = try XCTUnwrap((relationships["bundleIdCapabilities"] as? [String: Any])?["data"] as? [[String: Any]])
                XCTAssertEqual(capabilities.count, 1)
                XCTAssertEqual((capabilities[0]["attributes"] as? [String: Any])?["enabled"] as? Bool, true)
                let relation = try XCTUnwrap(capabilities[0]["relationships"] as? [String: Any])
                XCTAssertEqual(((relation["capability"] as? [String: Any])?["data"] as? [String: String])?["id"], "INCREASED_MEMORY_LIMIT")
                return (status, status == 204 ? Data() : Data("{\"data\":{\"type\":\"bundleIds\",\"id\":\"TESTID\"}}".utf8))
            }
            let result = try await AppleAPI.shared.updateAppID(appID, capabilities: ["INCREASED_MEMORY_LIMIT"], team: team, session: session, networkSession: network)
            XCTAssertEqual(result.identifier, appID.identifier)
            // The legacy AppID model is not evidence of installed entitlements.
            XCTAssertTrue(result.entitlements.isEmpty)
        }
    }

    private static func requestBody(_ request: URLRequest) throws -> Data {
        if let body = request.httpBody { return body }
        let stream = try XCTUnwrap(request.httpBodyStream)
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }
}

private final class CapabilityMockProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.handler!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/vnd.api+json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
