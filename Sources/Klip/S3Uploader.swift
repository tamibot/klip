import Foundation
import CryptoKit

/// Shares a clip through the user's OWN S3-compatible bucket — AWS S3, Cloudflare R2, Backblaze B2,
/// MinIO, DigitalOcean… one credential set covers them all. No hosted Klip service on purpose:
/// user-owned storage is the only cloud that fits local-first, and every upload is a deliberate
/// per-item click, never automatic.
///
/// The request is a SigV4-signed PUT built with pure CryptoKit (SHA-256 + an HMAC key chain) — no
/// SDK. Path-style URLs (`endpoint/bucket/key`), because R2 and MinIO reject virtual-host style,
/// and the REAL payload hash is always signed: `UNSIGNED-PAYLOAD` shortcuts break on some clones.
enum S3Uploader {
    struct Config {
        var endpoint: URL
        var region: String
        var bucket: String
        var accessKey: String
        var secretKey: String
        var publicBase: URL
    }

    enum ShareError: LocalizedError {
        case notConfigured
        case badResponse
        case server(Int, String)

        var errorDescription: String? {
            switch self {
            case .notConfigured: return L10n.t("share.notConfigured")
            case .badResponse:   return L10n.t("share.badResponse")
            // Surface the server's own words: SigV4 failures (clock skew >15 min, wrong region)
            // come back as an opaque 403 whose body is the only useful diagnostic.
            case .server(let code, let body):
                let hint = body.prefix(160).trimmingCharacters(in: .whitespacesAndNewlines)
                return "HTTP \(code)" + (hint.isEmpty ? "" : " — \(hint)")
            }
        }
    }

    /// The saved configuration, or nil while any field is missing (drives the UI's enabled state).
    static var configured: Config? {
        let s = Settings.shared
        guard let ep = URL(string: s.s3Endpoint.trimmingCharacters(in: .whitespacesAndNewlines)),
              ep.scheme?.hasPrefix("http") == true,
              !s.s3Bucket.isEmpty, !s.s3AccessKey.isEmpty,
              let pub = URL(string: s.s3PublicBase.trimmingCharacters(in: .whitespacesAndNewlines)),
              pub.scheme?.hasPrefix("http") == true,
              let secret = SecretStore.get(.s3)
        else { return nil }
        return Config(endpoint: ep, region: s.s3Region.isEmpty ? "auto" : s.s3Region,
                      bucket: s.s3Bucket, accessKey: s.s3AccessKey, secretKey: secret,
                      publicBase: pub)
    }

    static var isConfigured: Bool { configured != nil }

    /// Uploads `data` as `klip/UUID.ext` and returns the public share link. The UUID key is
    /// deliberate: object names must never leak the clip's own name.
    static func upload(data: Data, ext: String, contentType: String) async throws -> URL {
        guard let config = configured else { throw ShareError.notConfigured }
        let key = "klip/\(UUID().uuidString).\(ext)"
        try await send(method: "PUT", key: key, payload: data, contentType: contentType, config: config)
        return config.publicBase.appendingPathComponent(key)
    }

    /// Preferences' "Test connection": a tiny PUT then DELETE, so a bad credential/endpoint fails
    /// here instead of on the first real share.
    static func testConnection(_ config: Config) async throws {
        let key = "klip/connection-test-\(UUID().uuidString).txt"
        try await send(method: "PUT", key: key, payload: Data("klip".utf8),
                       contentType: "text/plain", config: config)
        try await send(method: "DELETE", key: key, payload: Data(), contentType: nil, config: config)
    }

    private static func send(method: String, key: String, payload: Data,
                             contentType: String?, config: Config) async throws {
        let request = signedRequest(method: method, key: key, payload: payload,
                                    contentType: contentType, config: config, now: Date())
        let (body, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ShareError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw ShareError.server(http.statusCode, String(data: body, encoding: .utf8) ?? "")
        }
    }

    // MARK: - SigV4 (internal, exercised by the test target against AWS's documented vectors)

    static func signedRequest(method: String, key: String, payload: Data,
                              contentType: String?, config: Config, now: Date) -> URLRequest {
        let url = config.endpoint.appendingPathComponent(config.bucket).appendingPathComponent(key)
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        df.timeZone = TimeZone(identifier: "UTC")
        df.locale = Locale(identifier: "en_US_POSIX")
        let amzDate = df.string(from: now)
        let dateStamp = String(amzDate.prefix(8))
        let payloadHash = sha256Hex(payload)
        let host = url.port.map { "\(url.host ?? ""):\($0)" } ?? (url.host ?? "")

        var headers: [(String, String)] = [
            ("host", host),
            ("x-amz-content-sha256", payloadHash),
            ("x-amz-date", amzDate),
        ]
        if let contentType { headers.append(("content-type", contentType)) }
        headers.sort { $0.0 < $1.0 }
        let canonicalHeaders = headers.map { "\($0.0):\($0.1)\n" }.joined()
        let signedHeaders = headers.map(\.0).joined(separator: ";")

        let canonicalRequest = [method, url.path, "", canonicalHeaders, signedHeaders, payloadHash]
            .joined(separator: "\n")
        let scope = "\(dateStamp)/\(config.region)/s3/aws4_request"
        let stringToSign = ["AWS4-HMAC-SHA256", amzDate, scope,
                            sha256Hex(Data(canonicalRequest.utf8))].joined(separator: "\n")
        let signature = hmacHex(key: signingKey(secret: config.secretKey, dateStamp: dateStamp,
                                                region: config.region, service: "s3"),
                                message: stringToSign)

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = payload
        request.setValue(payloadHash, forHTTPHeaderField: "x-amz-content-sha256")
        request.setValue(amzDate, forHTTPHeaderField: "x-amz-date")
        if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        request.setValue("AWS4-HMAC-SHA256 Credential=\(config.accessKey)/\(scope), " +
                         "SignedHeaders=\(signedHeaders), Signature=\(signature)",
                         forHTTPHeaderField: "Authorization")
        return request
    }

    /// The SigV4 key chain: HMAC("AWS4"+secret, date) → region → service → "aws4_request".
    static func signingKey(secret: String, dateStamp: String, region: String, service: String) -> Data {
        var key = hmac(key: Data(("AWS4" + secret).utf8), message: dateStamp)
        key = hmac(key: key, message: region)
        key = hmac(key: key, message: service)
        key = hmac(key: key, message: "aws4_request")
        return key
    }

    private static func hmac(key: Data, message: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: key)))
    }
    private static func hmacHex(key: Data, message: String) -> String {
        hmac(key: key, message: message).map { String(format: "%02x", $0) }.joined()
    }
    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
