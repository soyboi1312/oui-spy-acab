import Foundation

/// Automatic firmware network traffic is limited to the project's static download host. Hashes,
/// signatures, and on-board verification protect bytes; this policy separately protects the
/// privacy promise by preventing a malformed manifest from making the app contact another host.
enum FirmwareDownloadPolicy {
    nonisolated static func permits(_ url: URL?) -> Bool {
        guard let url else { return false }
        return url.scheme?.lowercased() == "https"
            && url.host?.lowercased() == "soyboi.tech"
            && url.user == nil
            && url.password == nil
            && (url.port == nil || url.port == 443)
    }

    nonisolated static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(
            configuration: configuration,
            delegate: FirmwareDownloadRejectRedirectsDelegate(),
            delegateQueue: nil
        )
    }
}

private final class FirmwareDownloadRejectRedirectsDelegate: NSObject, URLSessionTaskDelegate,
    @unchecked Sendable {
    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
