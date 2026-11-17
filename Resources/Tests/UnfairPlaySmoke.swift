import Foundation

/// Invented test enrollments are generated on the builder and copied only into
/// this smoke application. They must never enter the released application.
@MainActor
enum UnfairPlaySmoke {
    static func run() async throws {
        guard let fixtures = Bundle.main.url(forResource: "UnfairPlayFixtures", withExtension: nil) else {
            throw StoreRuntimeError.startup("unfairplay-fixtures-missing")
        }
        let input = fixtures.appendingPathComponent("input.ipa")
        let original = try bytes(input)
        let models = try ["model-main.bin", "model-widget.bin"].map { try bytes(fixtures.appendingPathComponent($0)) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let runtime = UnfairPlayRuntime.shared

        stage("models")
        let inspected = try await runtime.run(.modelInspect, models: models)
        try require(inspected.ready == true && inspected.modelCount == 2 && inspected.modelVersions == [2, 2])

        stage("inventory")
        let inventory = try await runtime.run(.doctor, input: input)
        try require(inventory.ready == false && inventory.encryptedImages == 2 && inventory.plaintextVerified == false)
        let doctor = try await runtime.run(.doctor, input: input, models: models)
        try require(doctor.ready == true && doctor.plaintextVerified == true)

        stage("verify")
        let verified = try await runtime.run(.verify, input: input, models: models)
        try require(verified.plaintextVerified == true && verified.encryptedImages == 2 && verified.decryptedPages == 2)
        try require(verified.outputPath == nil && (try FileManager.default.contentsOfDirectory(atPath: directory.path)).isEmpty)

        stage("decrypt")
        let output = directory.appendingPathComponent("decrypted.ipa")
        let decrypted = try await runtime.run(.decrypt, input: input, output: output, models: models)
        try require(decrypted.outputPath == output.path && decrypted.plaintextVerified == true)
        let firstOutput = try bytes(output)
        try require(!firstOutput.isEmpty && firstOutput != original)
        try await fails("output_exists") { try await runtime.run(.decrypt, input: input, output: output, models: models) }
        try require(try bytes(output) == firstOutput)

        stage("redact")
        let redacted = try await runtime.run(.decrypt, input: input,
            output: directory.appendingPathComponent("decrypted-redacted.ipa"), models: models, stripAccountData: true)
        try require(redacted.accountDataStripped == true && redacted.plaintextVerified == true
                    && redacted.removedLicenseFiles == 4 && redacted.removedMetadataFields == 3)
        let stripped = try await runtime.run(.stripAccountData, input: input,
            output: directory.appendingPathComponent("redacted.ipa"))
        try require(stripped.accountDataStripped == true && stripped.plaintextVerified == false
                    && stripped.removedLicenseFiles == 4 && stripped.removedMetadataFields == 3)

        stage("conversion")
        let converted = try await runtime.run(.convertIPAMacOS,
            input: fixtures.appendingPathComponent("conversion-input.ipa"),
            output: directory.appendingPathComponent("macos.ipa"),
            models: [try bytes(fixtures.appendingPathComponent("conversion-model.bin"))])
        try require(converted.outputPath != nil && converted.plaintextVerified == false)

        stage("boundaries")
        try await fails("invalid_model") { try await runtime.run(.modelInspect, models: [Data(repeating: 0, count: 4184)]) }
        let requestID = UUID().uuidString
        requestID.withCString { asspp_unfairplay_cancel($0) }
        let request = try JSONSerialization.data(withJSONObject: [
            "operation": "model_inspect", "requestID": requestID,
            "models": [models[0].base64EncodedString()],
        ])
        let text = String(decoding: request, as: UTF8.self)
        guard let response = text.withCString({ asspp_unfairplay_call($0) }) else {
            throw StoreRuntimeError.startup("unfairplay-allocation")
        }
        defer { asspp_unfairplay_free(response) }
        let count = strnlen(response, 1024 * 1024 + 1)
        try require(count > 0 && count <= 1024 * 1024)
        let result = try JSONSerialization.jsonObject(with: Data(bytes: response, count: count)) as? [String: Any]
        try require(result?["error"] as? String == "canceled")
        try require(try bytes(input) == original)
        print("Native UnfairPlay checks passed")
        fflush(stdout)
    }

    private static func bytes(_ url: URL) throws -> Data {
        let metadata = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard metadata.isRegularFile == true, metadata.isSymbolicLink != true,
              let size = metadata.fileSize, size > 0, size <= 256 * 1024 else {
            throw StoreRuntimeError.startup("unfairplay-fixture-size")
        }
        return try Data(contentsOf: url)
    }

    private static func stage(_ value: String) {
        StoreRuntimeSmoke.record("running:unfairplay-" + value)
        print("Native UnfairPlay " + value + " starting")
        fflush(stdout)
    }

    private static func require(_ condition: Bool) throws {
        if !condition { throw StoreRuntimeError.startup("unfairplay-check") }
    }

    private static func fails(_ code: String, operation: () async throws -> UnfairPlayReport) async throws {
        do { _ = try await operation() }
        catch UnfairPlayError.native(let actual) { try require(actual == code); return }
        throw StoreRuntimeError.startup("unfairplay-error-boundary")
    }
}
