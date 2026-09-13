import Foundation

/// Shared validation and safe, actionable errors for diagnostic transport.
/// Never include tokens, signed query strings, or server response bodies in UI/logs.
public enum DiagnosticUploadProtocol {
    public enum Failure: Error, LocalizedError, Equatable {
        case configuration(String)
        case http(stage: String, status: Int)
        case invalidResponse

        public var errorDescription: String? {
            switch self {
            case .configuration(let message): return message
            case .invalidResponse: return "Upload API returned an invalid or insecure upload URL."
            case .http(let stage, let status):
                switch status {
                case 401, 403:
                    return stage == "API"
                        ? "API reachable, but access was denied (HTTP \(status)). Check the beta upload key."
                        : "S3 rejected the upload (HTTP \(status)). Check signing, expiration and bucket permissions."
                case 404: return "\(stage) returned HTTP 404. Check the upload endpoint and /presign route."
                case 429: return "\(stage) rate limit reached (HTTP 429). Wait and retry."
                default: return "\(stage) request failed (HTTP \(status)). Retry or check the service."
                }
            }
        }
    }

    public static func endpoint(base: String, token: String) throws -> URL {
        let base = base.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { throw Failure.configuration("Upload endpoint is missing from this build.") }
        guard !token.isEmpty else { throw Failure.configuration("Upload key is missing from this build.") }
        guard !base.contains("$("), !token.contains("$(") else {
            throw Failure.configuration("Upload build settings were not expanded. Rebuild with the beta configuration.")
        }
        guard let url = URL(string: base), url.scheme == "https", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
            throw Failure.configuration("Upload endpoint must be an absolute HTTPS URL without a query or credentials.")
        }
        // Accept either the API base or the complete route, including trailing slash.
        return url.lastPathComponent == "presign"
            ? url.deletingLastPathComponent().appendingPathComponent("presign")
            : url.appendingPathComponent("presign")
    }

    public static func requestURL(endpoint: URL, installID: String,
                                  session: String, timestamp: Int) throws -> URL {
        guard var parts = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw Failure.invalidResponse
        }
        parts.queryItems = [URLQueryItem(name: "installID", value: installID),
                            URLQueryItem(name: "session", value: session),
                            URLQueryItem(name: "ts", value: String(timestamp))]
        guard let url = parts.url else { throw Failure.invalidResponse }
        return url
    }

    public static func uploadURL(data: Data, status: Int) throws -> URL {
        guard (200..<300).contains(status) else { throw Failure.http(stage: "API", status: status) }
        struct Presign: Decodable { let uploadURL: String }
        guard let result = try? JSONDecoder().decode(Presign.self, from: data),
              let url = URL(string: result.uploadURL), url.scheme == "https",
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
              url.fragment == nil else { throw Failure.invalidResponse }
        return url
    }

    public static func networkMessage(_ error: Error) -> String {
        if let known = error as? Failure { return known.localizedDescription }
        switch (error as NSError).code {
        case NSURLErrorNotConnectedToInternet, NSURLErrorDataNotAllowed:
            return "No permitted network connection. Connect to Wi-Fi; diagnostic uploads do not use cellular data."
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
            return "Upload host could not be found. Check the endpoint and your network's DNS."
        case NSURLErrorTimedOut: return "Connection timed out. Try another Wi-Fi network or retry."
        case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted:
            return "HTTPS certificate or secure connection failed. Check the endpoint and device date/time."
        case NSURLErrorCancelled: return "Request cancelled. Try again."
        default: return "Network request failed (code \((error as NSError).code)). Retry on Wi-Fi."
        }
    }
}
