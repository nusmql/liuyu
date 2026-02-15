// Tests/LiuyuTests/ProviderConfigTests.swift
import XCTest
@testable import LiuyuLib

final class ProviderConfigTests: XCTestCase {

    func testProviderConfigCodableRoundtrip() throws {
        let config = ProviderConfig(provider: .openai, baseURL: "https://custom.endpoint.com")
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(ProviderConfig.self, from: data)

        XCTAssertEqual(config.id, decoded.id)
        XCTAssertEqual(config.provider, decoded.provider)
        XCTAssertEqual(config.baseURL, decoded.baseURL)
    }

    func testProviderConfigKeychainKey() {
        let config = ProviderConfig(provider: .groq)
        XCTAssertTrue(config.keychainKey.hasPrefix("provider-"))
        XCTAssertTrue(config.keychainKey.contains(config.id.uuidString))
    }

    func testModelAssignmentCodableRoundtrip() throws {
        let providerID = UUID()
        let assignment = ModelAssignment(providerID: providerID, modelId: "whisper-1")
        let data = try JSONEncoder().encode(assignment)
        let decoded = try JSONDecoder().decode(ModelAssignment.self, from: data)

        XCTAssertEqual(assignment.providerID, decoded.providerID)
        XCTAssertEqual(assignment.modelId, decoded.modelId)
    }

    func testFeatureConfigCodableRoundtrip() throws {
        let pid = UUID()
        let config = FeatureConfig(
            sttPrimary: ModelAssignment(providerID: pid, modelId: "whisper-1"),
            llmPrimary: ModelAssignment(providerID: pid, modelId: "gpt-4o-mini")
        )
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(FeatureConfig.self, from: data)

        XCTAssertEqual(decoded.sttPrimary?.modelId, "whisper-1")
        XCTAssertEqual(decoded.llmPrimary?.modelId, "gpt-4o-mini")
        XCTAssertNil(decoded.sttFallback)
        XCTAssertNil(decoded.llmFallback)
    }
}
