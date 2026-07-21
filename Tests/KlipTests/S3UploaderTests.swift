import Testing
import Foundation
@testable import Klip

/// SigV4 signing pinned against AWS's own documented example — the derived-key vector from the
/// "Signature Version 4 signing process" docs. If the HMAC chain, ordering, or encoding drifts,
/// every upload turns into an opaque 403; this catches it at test time instead.
@Suite("S3Uploader SigV4")
struct S3UploaderTests {

    /// AWS's published example: secret wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY, 20150830,
    /// us-east-1, iam → kSigning c4afb1cc5771d871763a393e44b703571b55cc28424d1a5e86da6ed3c154a4b9.
    @Test("derived signing key matches AWS's documented vector")
    func signingKeyVector() {
        let key = S3Uploader.signingKey(secret: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
                                        dateStamp: "20150830", region: "us-east-1", service: "iam")
        let hex = key.map { String(format: "%02x", $0) }.joined()
        #expect(hex == "c4afb1cc5771d871763a393e44b703571b55cc28424d1a5e86da6ed3c154a4b9")
    }

    @Test("signed PUT carries every required header and a well-formed authorization")
    func signedRequestShape() throws {
        let config = S3Uploader.Config(
            endpoint: URL(string: "https://account.r2.cloudflarestorage.com")!,
            region: "auto", bucket: "clips", accessKey: "AKIDEXAMPLE",
            secretKey: "secret", publicBase: URL(string: "https://pub.example.com")!)
        let now = Date(timeIntervalSince1970: 1_700_000_000)   // fixed: signatures are date-dependent
        let request = S3Uploader.signedRequest(method: "PUT", key: "klip/abc.png",
                                               payload: Data("x".utf8), contentType: "image/png",
                                               config: config, now: now)
        #expect(request.url?.absoluteString == "https://account.r2.cloudflarestorage.com/clips/klip/abc.png")
        #expect(request.httpMethod == "PUT")
        let auth = try #require(request.value(forHTTPHeaderField: "Authorization"))
        #expect(auth.hasPrefix("AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20231114/auto/s3/aws4_request"))
        #expect(auth.contains("SignedHeaders=content-type;host;x-amz-content-sha256;x-amz-date"))
        // 64 hex chars of signature at the tail.
        let sig = auth.components(separatedBy: "Signature=").last ?? ""
        #expect(sig.count == 64 && sig.allSatisfy { $0.isHexDigit })
        #expect(request.value(forHTTPHeaderField: "x-amz-date") == "20231114T221320Z")
        // Real payload hash, never UNSIGNED-PAYLOAD (breaks on some S3 clones).
        let payloadHash = try #require(request.value(forHTTPHeaderField: "x-amz-content-sha256"))
        #expect(payloadHash == "2d711642b726b04401627ca9fbac32f5c8530fb1903cc4db02258717921a4881")   // sha256("x")
    }

    @Test("signing is deterministic for identical inputs")
    func deterministic() {
        let config = S3Uploader.Config(
            endpoint: URL(string: "https://s3.amazonaws.com")!, region: "us-east-1",
            bucket: "b", accessKey: "AK", secretKey: "SK",
            publicBase: URL(string: "https://cdn.example.com")!)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let a = S3Uploader.signedRequest(method: "PUT", key: "k.txt", payload: Data("hi".utf8),
                                         contentType: "text/plain", config: config, now: now)
        let b = S3Uploader.signedRequest(method: "PUT", key: "k.txt", payload: Data("hi".utf8),
                                         contentType: "text/plain", config: config, now: now)
        #expect(a.value(forHTTPHeaderField: "Authorization") == b.value(forHTTPHeaderField: "Authorization"))
    }
}
