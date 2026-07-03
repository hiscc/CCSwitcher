import XCTest

final class AccountBackupTests: XCTestCase {
    func testDecodeLegacyBackupWithoutRelayField() throws {
        let json = #"{"token":"tok-json","oauthAccount":{"emailAddress":"a@b.c"}}"#
        let backup = try JSONDecoder().decode(AccountBackup.self, from: Data(json.utf8))
        XCTAssertEqual(backup.token, "tok-json")
        XCTAssertNil(backup.relay)
        XCTAssertEqual(backup.oauthAccount["emailAddress"]?.value as? String, "a@b.c")
    }

    func testRelayBackupRoundTrip() throws {
        let original = AccountBackup(
            token: "sk-relay-token",
            oauthAccount: [:],
            relay: RelayInfo(name: "xtoken 0.18", baseURL: "https://api.xtokenmirror.com")
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AccountBackup.self, from: data)
        XCTAssertEqual(decoded.token, "sk-relay-token")
        XCTAssertEqual(decoded.relay, RelayInfo(name: "xtoken 0.18", baseURL: "https://api.xtokenmirror.com"))
    }

    func testNilRelayIsOmittedFromJSON() throws {
        let backup = AccountBackup(token: "t", oauthAccount: [:])
        let data = try JSONEncoder().encode(backup)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertNil(json["relay"], "nil relay must be absent from JSON, not \"relay\":null")
    }

    func testExplicitNullRelayDecodesAsNil() throws {
        let json = #"{"token":"t","oauthAccount":{},"relay":null}"#
        let backup = try JSONDecoder().decode(AccountBackup.self, from: Data(json.utf8))
        XCTAssertNil(backup.relay)
    }

    func testMixedStoreDecodes() throws {
        let json = #"""
        {"A":{"token":"t1","oauthAccount":{"emailAddress":"a@b.c"}},
         "B":{"token":"sk-x","oauthAccount":{},"relay":{"name":"n","baseURL":"https://r.example"}}}
        """#
        let store = try JSONDecoder().decode([String: AccountBackup].self, from: Data(json.utf8))
        XCTAssertNil(store["A"]?.relay)
        XCTAssertEqual(store["B"]?.relay?.baseURL, "https://r.example")
    }
}
