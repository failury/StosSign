import Foundation
import XCTest
@testable import StosSign_Auth
import StosSign_Common

final class AuthenticationHeaderTests: XCTestCase {
    func testPushedCodeChallengeAndLegacyResponses() {
        XCTAssertEqual(Authentication.twoFactorChallenge(in: ["Status": ["hsc": 409]]), .trustedDevice(codeAlreadySent: true))
        XCTAssertEqual(Authentication.twoFactorChallenge(in: ["Status": ["hsc": 409, "au": ""]]), .trustedDevice(codeAlreadySent: true))
        XCTAssertEqual(Authentication.twoFactorChallenge(in: ["Status": ["au": "trustedDeviceSecondaryAuth"]]), .trustedDevice(codeAlreadySent: false))
        XCTAssertEqual(Authentication.twoFactorChallenge(in: ["Status": ["hsc": 409], "au": "secondaryAuth"]), .sms)
        XCTAssertNil(Authentication.twoFactorChallenge(in: ["Status": ["ec": -22411, "hsc": 401]]))
        XCTAssertNil(Authentication.twoFactorChallenge(in: ["Status": ["hsc": 200]]))
        XCTAssertNil(Authentication.twoFactorChallenge(in: ["Status": ["hsc": 409, "au": "repair"]]))
    }

    func testPushedCodeWaitsForInputAndRefreshesBeforeValidation() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockAppleProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel(); MockAppleProtocol.handler = nil }
        var events: [String] = []
        MockAppleProtocol.handler = { request in
            events.append("validate")
            XCTAssertEqual(request.url?.path, "/grandslam/GsService2/validate")
            XCTAssertEqual(request.value(forHTTPHeaderField: "security-code"), "123456")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Apple-I-MD"), "fresh-otp")
            return try PropertyListSerialization.data(fromPropertyList: ["ec": 0], format: .xml, options: 0)
        }
        try await Authentication.requestTrustedDeviceTwoFactorCode(
            dsid: "test", idmsToken: "test", anisetteData: anisette(), codeAlreadySent: true,
            anisetteDataRefreshHandler: {
                events.append("refresh")
                return AnisetteData(machineID: "test", oneTimePassword: "fresh-otp", localUserID: "test", routingInfo: 0,
                                    deviceUniqueIdentifier: "test", deviceSerialNumber: "0", deviceDescription: "test",
                                    date: Date(), locale: .current, timeZone: .current)
            }, session: session,
            verificationHandler: { callback in events.append("prompt"); callback("123456") })
        XCTAssertEqual(events, ["prompt", "refresh", "validate"])
    }

    func testLegacyChallengeStillRequestsCodeFirst() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockAppleProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel(); MockAppleProtocol.handler = nil }
        var events: [String] = []
        MockAppleProtocol.handler = { request in
            events.append(request.url!.path)
            return try PropertyListSerialization.data(fromPropertyList: ["ec": 0], format: .xml, options: 0)
        }
        try await Authentication.requestTrustedDeviceTwoFactorCode(
            dsid: "test", idmsToken: "test", anisetteData: anisette(), session: session,
            verificationHandler: { callback in events.append("prompt"); callback("123456") })
        XCTAssertEqual(events, ["/auth/verify/trusteddevice", "prompt", "/grandslam/GsService2/validate"])
    }

    func testCancellingPushedCodeDoesNotValidate() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockAppleProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel(); MockAppleProtocol.handler = nil }
        MockAppleProtocol.handler = { _ in XCTFail("Cancelled verification must not send a request"); return Data() }
        do {
            try await Authentication.requestTrustedDeviceTwoFactorCode(
                dsid: "test", idmsToken: "test", anisetteData: anisette(), codeAlreadySent: true, session: session,
                verificationHandler: { callback in callback(nil) })
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertEqual(error as? AppleAPIError, .requiresTwoFactorAuthentication)
        }
    }

    private func anisette(userAgent: String? = nil) -> AnisetteData {
        AnisetteData(machineID: "test-machine", oneTimePassword: "test-otp",
                     localUserID: "test-local", routingInfo: 0,
                     deviceUniqueIdentifier: "test-device", deviceSerialNumber: "0",
                     deviceDescription: "<PC> <Windows;6.2(0,0);9200> <com.apple.AuthKit/1 (com.apple.iTunes/12.12.4.1)>",
                     date: Date(timeIntervalSince1970: 0), locale: Locale(identifier: "en_US"),
                     timeZone: TimeZone(secondsFromGMT: 0)!, userAgent: userAgent)
    }

    func testGrandSlamOverrideAcrossAuthenticationOperations() throws {
        let data = anisette(userAgent: "akd/1.0 CFNetwork/808.1.4")
        for operation in ["init", "complete", "apptokens"] {
            let request = try Authentication.makeAuthenticationRequest(parameters: ["o": operation], anisetteData: data)
            XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), data.userAgent)
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-MMe-Client-Info"), data.deviceDescription)
            XCTAssertEqual(request.httpMethod, "POST")
            let body = try XCTUnwrap(request.httpBody)
            let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: body, format: nil) as? [String: Any])
            XCTAssertEqual((plist["Request"] as? [String: String])?["o"], operation)
        }
    }

    func testTwoFactorOverrideAndDefaults() throws {
        for path in ["auth/verify/trusteddevice", "grandslam/GsService2/validate", "auth/verify/phone/put", "auth/verify/phone/securitycode"] {
            let url = try XCTUnwrap(URL(string: "https://gsa.apple.com/\(path)"))
            let data = anisette(userAgent: "akd/1.0 CFNetwork/808.1.4")
            let request = Authentication.makeTwoFactorCodeRequest(url: url, dsid: "test", idmsToken: "test", anisetteData: data)
            XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), data.userAgent)
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-MMe-Client-Info"), data.deviceDescription)
            let original = Authentication.makeTwoFactorCodeRequest(url: url, dsid: "test", idmsToken: "test", anisetteData: anisette())
            XCTAssertEqual(original.value(forHTTPHeaderField: "User-Agent"), "Xcode")
        }
        let request = try Authentication.makeAuthenticationRequest(parameters: [:], anisetteData: anisette())
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "AuthKit/1 (Macintosh; OS X 26.6) (com.apple.dt.Xcode/26.0)")
    }

    func testDecodeWithAndWithoutOptionalUserAgent() throws {
        var json = ["machineID": "test", "oneTimePassword": "test", "localUserID": "test",
                    "routingInfo": "0", "deviceUniqueIdentifier": "test", "deviceSerialNumber": "0",
                    "deviceDescription": "test", "date": "2026-10-17T00:00:00Z", "locale": "en_US", "timeZone": "UTC"]
        XCTAssertNil(try JSONDecoder().decode(AnisetteData.self, from: JSONSerialization.data(withJSONObject: json)).userAgent)
        json["userAgent"] = "akd/1.0 CFNetwork/808.1.4"
        XCTAssertEqual(try JSONDecoder().decode(AnisetteData.self, from: JSONSerialization.data(withJSONObject: json)).userAgent, json["userAgent"])
    }
}

private final class MockAppleProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> Data)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let data = try Self.handler!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
