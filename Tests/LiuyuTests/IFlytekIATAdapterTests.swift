import XCTest
@testable import LiuyuLib

final class IFlytekIATAdapterTests: XCTestCase {
    func testCredentialsParsePipeSeparatedHMACValue() throws {
        let credentials = try XCTUnwrap(IFlytekIATCredentials.parse("appid|api-key|api-secret"))

        XCTAssertEqual(credentials.appID, "appid")
        XCTAssertEqual(credentials.authentication, .hmac(apiKey: "api-key", apiSecret: "api-secret"))
    }

    func testCredentialsParseOAuth2BearerValue() throws {
        let credentials = try XCTUnwrap(IFlytekIATCredentials.parse("oauth2|appid|access-token"))

        XCTAssertEqual(credentials.appID, "appid")
        XCTAssertEqual(credentials.authentication, .oauth2(accessToken: "access-token"))
    }

    func testSignedURLUsesHMACQueryAndDoesNotExposeSecret() throws {
        let date = Date(timeIntervalSince1970: 1_720_597_943)
        let credentials = IFlytekIATCredentials(
            appID: "appid",
            authentication: .hmac(apiKey: "api-key", apiSecret: "api-secret")
        )

        let url = try IFlytekIATAdapter.signedURL(
            endpoint: "wss://iat-api.xfyun.cn/v2/iat",
            credentials: credentials,
            date: date
        )

        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let queryItems = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })

        XCTAssertEqual(components.scheme, "wss")
        XCTAssertEqual(components.host, "iat-api.xfyun.cn")
        XCTAssertEqual(components.path, "/v2/iat")
        XCTAssertEqual(queryItems["host"], "iat-api.xfyun.cn")
        XCTAssertEqual(queryItems["date"], "Wed, 10 Jul 2024 07:52:23 GMT")
        XCTAssertNotNil(queryItems["authorization"])
        XCTAssertFalse(url.absoluteString.contains("api-secret"))
    }

    func testOAuth2CredentialsUseBearerHeader() {
        let adapter = IFlytekIATAdapter()
        let headers = adapter.buildWebSocketHeaders(config: .init(
            apiKey: "oauth2|appid|access-token",
            endpoint: "wss://iat-api.xfyun.cn/v2/iat",
            model: "iat-api-v2"
        ))

        XCTAssertEqual(headers["Authorization"], "Bearer access-token")
    }

    func testBuildFirstAudioFrameIncludesCommonBusinessAndBase64PCM() {
        let message = IFlytekIATAdapter.buildFrameMessage(
            appID: "appid",
            data: Data([1, 2, 3]),
            status: 0,
            includeCommonAndBusiness: true
        )

        let common = message["common"] as? [String: Any]
        let business = message["business"] as? [String: Any]
        let data = message["data"] as? [String: Any]

        XCTAssertEqual(common?["app_id"] as? String, "appid")
        XCTAssertEqual(business?["language"] as? String, "zh_cn")
        XCTAssertEqual(business?["domain"] as? String, "iat")
        XCTAssertEqual(data?["status"] as? Int, 0)
        XCTAssertEqual(data?["format"] as? String, "audio/L16;rate=16000")
        XCTAssertEqual(data?["encoding"] as? String, "raw")
        XCTAssertEqual(data?["audio"] as? String, Data([1, 2, 3]).base64EncodedString())
    }

    func testBuildFinalFrameUsesStatusOnlyPayload() {
        let message = IFlytekIATAdapter.buildFrameMessage(
            appID: "appid",
            data: Data(),
            status: 2,
            includeCommonAndBusiness: false
        )

        let data = message["data"] as? [String: Any]

        XCTAssertNil(message["common"])
        XCTAssertNil(message["business"])
        XCTAssertEqual(data?["status"] as? Int, 2)
        XCTAssertEqual(data?["audio"] as? String, "")
    }

    func testParseServerSegmentConcatenatesFirstCandidateWords() {
        let message = """
        {
          "code": 0,
          "message": "success",
          "data": {
            "status": 1,
            "result": {
              "sn": 1,
              "ls": false,
              "ws": [
                { "cw": [{ "w": "你好" }] },
                { "cw": [{ "w": "世界" }] }
              ]
            }
          }
        }
        """

        let parsed = IFlytekIATAdapter.parseServerMessage(message)

        XCTAssertEqual(parsed, .segment(sequence: 1, text: "你好世界", isFinal: false))
    }

    func testParseServerFinalNoSpeech() {
        let message = """
        {
          "code": 0,
          "message": "success",
          "data": {
            "status": 2,
            "result": {
              "sn": 2,
              "ls": true,
              "ws": []
            }
          }
        }
        """

        XCTAssertEqual(IFlytekIATAdapter.parseServerMessage(message), .finalNoSpeech)
    }

    func testParseServerError() {
        let message = """
        {
          "code": 11200,
          "message": "service not authorized"
        }
        """

        XCTAssertEqual(
            IFlytekIATAdapter.parseServerMessage(message),
            .error(code: 11200, message: "service not authorized")
        )
    }
}
