import Foundation

/// Shared plumbing for URL-sourced sync (vocabulary, people): request
/// building with sanitized auth headers, and status errors with
/// GitHub-specific credential hints.
enum RemoteSync {

    /// Fetch with sanitized headers and redirect protection. Use this instead
    /// of URLSession directly for any request that carries sync auth headers.
    static func fetch(url: URL, headers: [Store.HTTPHeader]) async throws -> (Data, URLResponse) {
        try await URLSession.shared.data(
            for: request(url: url, headers: headers), delegate: redirectGuard)
    }

    /// URLSession copies the original headers — Authorization included — onto
    /// every redirect request. A cross-host or non-https hop would replay the
    /// user's token somewhere it was never meant to go, so refuse to follow;
    /// the sync then surfaces the 3xx status as an error instead.
    private static let redirectGuard = RedirectGuard()

    private final class RedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(
            _ session: URLSession, task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping @Sendable (URLRequest?) -> Void
        ) {
            let sameHost = request.url?.host == task.originalRequest?.url?.host
            let https = request.url?.scheme?.lowercased() == "https"
            completionHandler(sameHost && https ? request : nil)
        }
    }

    /// Trim newlines too: a pasted token with a trailing newline makes
    /// CFNetwork silently drop the header. Skip blank rows entirely so an
    /// accidentally-added duplicate can't overwrite a real one (setValue
    /// replaces any earlier value for the same name).
    static func request(url: URL, headers: [Store.HTTPHeader]) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: 15)
        for header in headers {
            let name = header.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let value = header.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !value.isEmpty else { continue }
            request.setValue(value, forHTTPHeaderField: name)
        }
        return request
    }

    /// GitHub answers 404, not 401, for private files, which hides whether
    /// the problem is the URL, the credentials, or the token's access. Its
    /// rate-limit ceiling tells them apart: 60/hour means the request was
    /// treated as anonymous; authenticated requests get 5000+.
    static func gitHubHint(for response: HTTPURLResponse) -> String? {
        guard response.statusCode == 404,
              response.url?.host == "api.github.com" else { return nil }
        let limit = response.value(forHTTPHeaderField: "x-ratelimit-limit")
            .flatMap(Int.init) ?? 0
        return limit <= 60
            ? "GitHub did not receive valid credentials — check the Authorization header row (value: “Bearer <token>”)."
            : "GitHub recognized your token, but it does not grant access to this file — check the token's Repository access and Contents permission, and the file path."
    }

    enum SyncError: Error, LocalizedError {
        case badStatus(Int, hint: String?)
        var errorDescription: String? {
            switch self {
            case .badStatus(let code, let hint):
                let message = "Server returned HTTP \(code)."
                if let hint { return message + " " + hint }
                if code == 404 {
                    // Same ambiguity on non-GitHub hosts; say so generically.
                    return message + " Check the URL — private files can also return 404 when the Authorization header is missing or invalid."
                }
                if (300..<400).contains(code) {
                    return message + " Luxicon doesn't follow redirects to another host (they would carry your auth headers there) — point at the final URL directly."
                }
                return message
            }
        }
    }
}
