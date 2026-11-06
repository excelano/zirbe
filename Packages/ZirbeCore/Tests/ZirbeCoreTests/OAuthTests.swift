// Author: David M. Anderson
// Built with AI assistance (Claude, Anthropic)

import XCTest
import ZirbeMail
@testable import ZirbeCore

final class FakeOAuthHTTP: OAuthHTTP, @unchecked Sendable {
    struct Post: Equatable {
        let url: URL
        let form: [String: String]
    }

    private let lock = NSLock()
    private var responses: [(Int, String)]
    private var recorded: [Post] = []

    init(_ responses: [(Int, String)]) {
        self.responses = responses
    }

    var posts: [Post] { lock.withLock { recorded } }

    func post(_ url: URL, form: [String: String]) async throws -> (Data, Int) {
        try await Task.sleep(for: .milliseconds(10))
        return lock.withLock {
            recorded.append(Post(url: url, form: form))
            let (status, body) = responses.isEmpty ? (500, "{}") : responses.removeFirst()
            return (Data(body.utf8), status)
        }
    }
}

final class OAuthTests: XCTestCase {
    private let clock = Date(timeIntervalSince1970: 1_000_000)

    private func client(_ http: FakeOAuthHTTP) -> OAuthClient {
        OAuthClient(http: http, now: { [clock] in clock })
    }

    private func tokens(expiringIn seconds: TimeInterval, provider: OAuthProvider.ID = .microsoft) -> OAuthTokens {
        OAuthTokens(provider: provider, accessToken: "old-access", refreshToken: "old-refresh",
                    expiresAt: clock.addingTimeInterval(seconds))
    }

    private func authorization(_ provider: OAuthProvider = .microsoft) -> OAuthAuthorization {
        OAuthAuthorization(provider: provider, loginHint: "me@outlook.com", state: "s1",
                           codeVerifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
    }

    func testTheAuthorizationURLCarriesPKCEAndTheLoginHint() throws {
        let url = authorization().url
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let query = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })

        XCTAssertEqual(url.host, "login.microsoftonline.com")
        XCTAssertEqual(query["code_challenge"], "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM", "RFC 7636 appendix B")
        XCTAssertEqual(query["code_challenge_method"], "S256")
        XCTAssertEqual(query["state"], "s1")
        XCTAssertEqual(query["login_hint"], "me@outlook.com")
        XCTAssertEqual(query["redirect_uri"], "msauth.com.excelano.zirbe://auth")
        XCTAssertTrue(query["scope"]?.contains("offline_access") == true)
    }

    func testGoogleRedirectIsTheReversedClientID() {
        XCTAssertEqual(OAuthProvider.googleRedirectURI(clientID: "123-abc.apps.googleusercontent.com"),
                       "com.googleusercontent.apps.123-abc:/oauth2redirect")
        XCTAssertEqual(OAuthProvider.microsoft.callbackScheme, "msauth.com.excelano.zirbe")
    }

    func testTheCallbackYieldsTheCodeOnlyForItsOwnState() throws {
        let auth = authorization()

        XCTAssertEqual(try auth.code(from: URL(string: "msauth.com.excelano.zirbe://auth?code=abc&state=s1")!), "abc")
        XCTAssertThrowsError(try auth.code(from: URL(string: "msauth.com.excelano.zirbe://auth?code=abc&state=other")!)) {
            XCTAssertEqual($0 as? OAuthError, .stateMismatch)
        }
        XCTAssertThrowsError(try auth.code(from: URL(string: "msauth.com.excelano.zirbe://auth?error=access_denied&state=s1")!)) {
            XCTAssertEqual($0 as? OAuthError, .denied("access_denied"))
        }
    }

    func testRedeemingPostsTheVerifierAndReadsTheTokens() async throws {
        let http = FakeOAuthHTTP([(200, #"{"access_token":"a1","refresh_token":"r1","expires_in":3600}"#)])

        let tokens = try await client(http).redeem("abc", for: authorization())

        XCTAssertEqual(tokens, OAuthTokens(provider: .microsoft, accessToken: "a1", refreshToken: "r1",
                                           expiresAt: clock.addingTimeInterval(3600)))
        XCTAssertEqual(http.posts.first?.form["code_verifier"], "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        XCTAssertEqual(http.posts.first?.form["grant_type"], "authorization_code")
    }

    func testRedeemingWithoutARefreshTokenFails() async {
        let http = FakeOAuthHTTP([(200, #"{"access_token":"a1","expires_in":3600}"#)])

        do {
            _ = try await client(http).redeem("abc", for: authorization())
            XCTFail("expected the missing refresh token to fail")
        } catch {
            XCTAssertEqual(error as? OAuthError, .missingRefreshToken)
        }
    }

    func testARefreshWithoutANewRefreshTokenKeepsTheOldOne() async throws {
        let http = FakeOAuthHTTP([(200, #"{"access_token":"a2","expires_in":3600}"#)])

        let fresh = try await client(http).refresh(tokens(expiringIn: 0, provider: .google))

        XCTAssertEqual(fresh.accessToken, "a2")
        XCTAssertEqual(fresh.refreshToken, "old-refresh")
        XCTAssertNil(http.posts.first?.form["scope"], "Google refreshes without a scope")
    }

    func testARevokedRefreshTokenReadsAsARejectedSignIn() async {
        let http = FakeOAuthHTTP([(400, #"{"error":"invalid_grant"}"#)])

        do {
            _ = try await client(http).refresh(tokens(expiringIn: 0))
            XCTFail("expected invalid_grant to reject the sign-in")
        } catch {
            XCTAssertEqual(error as? MailEngineError, .authenticationRejected)
        }
    }

    func testTheSourceReusesAValidTokenAndRefreshesOnceWhenExpired() async throws {
        let http = FakeOAuthHTTP([(200, #"{"access_token":"a2","refresh_token":"r2","expires_in":3600}"#)])
        let saved = FakeCredentials()
        let valid = OAuthTokenSource(tokens: tokens(expiringIn: 600), client: client(http)) { _ in }
        let current = try await valid.accessToken()
        XCTAssertEqual(current, "old-access")
        XCTAssertTrue(http.posts.isEmpty)

        let expired = OAuthTokenSource(tokens: tokens(expiringIn: 30), client: client(http)) { fresh in
            try? saved.save(.oauth(fresh), for: "me@outlook.com")
        }
        async let first = expired.accessToken()
        async let second = expired.accessToken()
        let results = try await [first, second]

        XCTAssertEqual(results, ["a2", "a2"])
        XCTAssertEqual(http.posts.count, 1, "concurrent callers share one refresh")
        guard case .oauth(let stored)? = saved.stored["me@outlook.com"] else { return XCTFail("rotated tokens not saved") }
        XCTAssertEqual(stored.refreshToken, "r2")
    }
}
