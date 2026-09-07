import Foundation

actor PocketDraftAccumulator {
    private var files: [String: String] = [:]
    private let request: PocketAppGenerationRequest
    private let workspace: URL

    init(request: PocketAppGenerationRequest, workspace: URL) {
        self.request = request
        self.workspace = workspace
    }

    func write(_ args: [String: CodexJSONValue]) throws -> String {
        guard Set(args.keys) == ["path", "mode", "utf8"],
              let path = args["path"]?.stringValue, PocketAppGenerationMaterializer.safeGeneratedPath(path),
              let mode = args["mode"]?.stringValue, ["replace", "append"].contains(mode),
              let chunk = args["utf8"]?.stringValue, chunk.count <= 12_000, !chunk.contains("\0"),
              mode != "append" || files[path] != nil else { throw PocketAppGenerationError.invalidRequest }
        let text = (mode == "append" ? files[path] ?? "" : "") + chunk
        guard text.utf8.count <= PocketAppPackageRuntime.maximumFileBytes,
              files.count < PocketAppPackageRuntime.maximumFiles || files[path] != nil,
              files.filter({ $0.key != path }).values.reduce(text.utf8.count, { $0 + $1.utf8.count }) <= PocketAppGenerationContract.maximumOutputBytes else {
            throw PocketAppGenerationError.outputLimitExceeded
        }
        files[path] = text
        return "Accepted \(text.utf8.count) bytes for \(path). Draft contains \(files.count) files."
    }

    func validatedEnvelope() throws -> PocketAppGenerationEnvelope {
        let generated = files.sorted(by: { $0.key < $1.key }).map { PocketAppGeneratedFile(path: $0.key, utf8: $0.value) }
        let snapshot = PocketAppFileSnapshot(rootDirectory: workspace,
            files: files.mapValues { Data($0.utf8) }, identities: [:])
        _ = try PocketAppPackageRuntime().load(snapshot: snapshot)
        let envelope = PocketAppGenerationEnvelope(requestID: request.requestID, requestDigest: request.requestDigest,
            appID: request.appID, version: request.version, namespace: request.namespace, files: generated)
        let result = try PocketAppGenerationMaterializer(rootDirectory: workspace).materialize(envelope: envelope, request: request)
        defer { try? FileManager.default.removeItem(at: result.directory) }
        _ = try PocketAppStagingTestRunner().run(result.package)
        return envelope
    }
}
