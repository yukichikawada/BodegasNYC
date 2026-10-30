import Auth
import Foundation

/// Calls the `delete-account` edge function (#127, spec item 3) as one
/// `URLRequest`, with the user's access token as the bearer. The function
/// revokes Sign in with Apple (when the user has an Apple identity), deletes
/// the auth user and sweeps their photos out of Storage; see
/// `supabase/functions/delete-account/lib.ts` for the contract.
///
/// Signing out locally afterwards is the caller's job (`AccountViewModel`).
nonisolated struct AccountService: Sendable {
    typealias Fetch = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    /// What a successful call means for the terminal line (design DS6).
    enum Outcome: Equatable, Sendable {
        /// 204: the account is gone and so are its photos.
        case deleted
        /// 202 `cleanup_pending`: the account is gone; the photo sweep
        /// failed twice and some objects remain for now.
        case deletedCleanupPending
    }

    enum Error: Swift.Error, Equatable, Sendable {
        /// No session to send: the user is not signed in on this device.
        case notSignedIn
        /// The function answered something other than 204/202. `code` is the
        /// body's stable `code` when it parsed, else `nil`; callers map by
        /// `code` first and fall back to `status`.
        case server(status: Int, code: String?, message: String?)
        /// The request never got an HTTP answer (or the session refresh
        /// failed on the way). The description is for logs only.
        case transport(String)
    }

    private let auth: AuthClient
    private let functionsURL: URL
    private let anonKey: String
    private let fetch: Fetch

    init(auth: AuthClient, functionsURL: URL, anonKey: String, fetch: @escaping Fetch) {
        self.auth = auth
        self.functionsURL = functionsURL
        self.anonKey = anonKey
        self.fetch = fetch
    }

    var deleteAccountURL: URL { functionsURL.appendingPathComponent("delete-account") }

    /// POSTs `{"appleAuthorizationCode": <code or null>}`. `auth.session`
    /// refreshes an expired access token first.
    func deleteAccount(appleAuthorizationCode: String?) async throws(Error) -> Outcome {
        let session: Session
        do {
            session = try await auth.session
        } catch AuthError.sessionMissing {
            throw .notSignedIn
        } catch {
            throw .transport(String(describing: error))
        }

        var request = URLRequest(url: deleteAccountURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // An explicit `null` when there is no code (a synthesized `Encodable`
        // would omit the key).
        let body: [String: Any] = ["appleAuthorizationCode": appleAuthorizationCode ?? NSNull()]
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            throw .transport(String(describing: error))
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await fetch(request)
        } catch {
            throw .transport(String(describing: error))
        }
        guard let http = response as? HTTPURLResponse else {
            throw .transport("not an HTTP response")
        }
        switch http.statusCode {
        case 204:
            return .deleted
        case 202:
            return .deletedCleanupPending
        default:
            let body = try? JSONDecoder().decode(ErrorBody.self, from: data)
            throw .server(status: http.statusCode, code: body?.code, message: body?.message)
        }
    }

    private struct ErrorBody: Decodable {
        let code: String?
        let message: String?
    }
}
