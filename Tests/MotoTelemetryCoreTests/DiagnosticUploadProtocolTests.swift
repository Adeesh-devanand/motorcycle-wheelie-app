import XCTest
@testable import MotoTelemetryCore

final class DiagnosticUploadProtocolTests: XCTestCase {
    func testEndpointAcceptsBaseOrFullRouteWithoutDuplication() throws {
        for base in ["https://api.example.com", "https://api.example.com/", "https://api.example.com/presign", "https://api.example.com/presign/"] {
            XCTAssertEqual(try DiagnosticUploadProtocol.endpoint(base: base, token: "test").absoluteString,
                           "https://api.example.com/presign")
        }
        XCTAssertEqual(try DiagnosticUploadProtocol.endpoint(base: "https://api.example.com/beta/", token: "test").path,
                       "/beta/presign")
    }

    func testMissingUnexpandedAndUnsafeConfigurationRejected() {
        for base in ["", "$(BetaUploadAPIBase)", "http://api.example.com", "api.example.com", "https://user:pass@api.example.com", "https://api.example.com?secret=x", "https://api.example.com#fragment"] {
            XCTAssertThrowsError(try DiagnosticUploadProtocol.endpoint(base: base, token: "test"))
        }
        for key in ["", " ", "$(BetaUploadToken)"] {
            XCTAssertThrowsError(try DiagnosticUploadProtocol.endpoint(base: "https://api.example.com", token: key))
        }
    }

    func testRequestsPreserveStageAndEncodeQueryParameters() throws {
        let endpoint = try DiagnosticUploadProtocol.endpoint(base: "https://api.example.com/beta", token: "private")
        let url = try DiagnosticUploadProtocol.requestURL(endpoint: endpoint, installID: "install-test",
                                                          session: "session-test", timestamp: 1700000000000)
        XCTAssertEqual(url.path, "/beta/presign")
        let qs = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(qs?.first(where: { $0.name == "installID" })?.value, "install-test")
        XCTAssertFalse(url.absoluteString.contains("private"))
    }

    func testPresignRequiresSuccessfulHTTPAndSecureURL() throws {
        let good = Data(#"{"uploadURL":"https://bucket.s3.amazonaws.com/beta/test?X-Amz-Signature=private"}"#.utf8)
        XCTAssertEqual(try DiagnosticUploadProtocol.uploadURL(data: good, status: 200).host, "bucket.s3.amazonaws.com")
        for code in [401, 403, 404, 429, 500] {
            XCTAssertThrowsError(try DiagnosticUploadProtocol.uploadURL(data: good, status: code)) { error in
                XCTAssertTrue(error.localizedDescription.contains(String(code)))
                XCTAssertFalse(error.localizedDescription.contains("private"))
            }
        }
        for bad in ["not json", "{}", #"{"uploadURL":"http://bucket.example.com"}"#, #"{"uploadURL":"/relative"}"#] {
            XCTAssertThrowsError(try DiagnosticUploadProtocol.uploadURL(data: Data(bad.utf8), status: 200))
        }
    }

    func testTransportErrorsAreActionableAndRedactURLs() {
        for code in [NSURLErrorNotConnectedToInternet, NSURLErrorTimedOut, NSURLErrorCannotFindHost, NSURLErrorSecureConnectionFailed, NSURLErrorCancelled] {
            let error = NSError(domain: NSURLErrorDomain, code: code,
                                userInfo: [NSLocalizedDescriptionKey: "https://secret.example/?token=private"])
            let message = DiagnosticUploadProtocol.networkMessage(error)
            XCTAssertFalse(message.contains("private"))
            XCTAssertFalse(message.contains("secret.example"))
            XCTAssertFalse(message.isEmpty)
        }
    }
}
