import Foundation
import XCTest
import StosSign_Auth
import StosSign_Common

final class AuthenticationHeaderTests: XCTestCase {
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
