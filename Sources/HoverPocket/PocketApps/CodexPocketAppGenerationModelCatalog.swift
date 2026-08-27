import CryptoKit
import Darwin
import Foundation

enum CodexPocketAppGenerationModelCatalog {
    static let modelID = "gpt-5.6-sol"
    static let reasoningEffort = "medium"
    static let expectedDigest = "bc11d3320055b4e235ecefe823fd78017e1a526b893541cc936fa0708d0d515c"
    static let fileName = "codex-model-catalog.v1.json"
    static let maximumBytes = 64 * 1024

    static func load() throws -> Data {
        guard let resources = Bundle.module.resourceURL else {
            throw PocketAppGenerationError.generatorUnavailable
        }
        let pocketApps = resources.appendingPathComponent("PocketApps", isDirectory: true)
        let hostAssets = pocketApps.appendingPathComponent("_Host", isDirectory: true)
        let catalogURL = hostAssets.appendingPathComponent(fileName, isDirectory: false).standardizedFileURL
        guard catalogURL.deletingLastPathComponent() == hostAssets.standardizedFileURL else {
            throw PocketAppGenerationError.generatorUnavailable
        }
        var metadata = stat()
        guard catalogURL.path.withCString({ lstat($0, &metadata) }) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              (metadata.st_mode & (S_IWGRP | S_IWOTH)) == 0,
              metadata.st_size > 0,
              metadata.st_size <= maximumBytes else {
            throw PocketAppGenerationError.generatorUnavailable
        }
        let data = try Data(contentsOf: catalogURL, options: [.mappedIfSafe])
        try validate(data)
        return data
    }

    static func validate(_ data: Data) throws {
        guard !data.isEmpty,
              data.count <= maximumBytes,
              SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == expectedDigest,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(root.keys) == ["models"],
              let models = root["models"] as? [[String: Any]],
              models.count == 1,
              let model = models.first,
              model["slug"] as? String == modelID,
              model["default_reasoning_level"] as? String == reasoningEffort,
              model["supported_in_api"] as? Bool == true,
              model["supports_parallel_tool_calls"] as? Bool == false,
              model["supports_search_tool"] as? Bool == false,
              model["tool_mode"] is NSNull,
              model["multi_agent_version"] is NSNull,
              model["base_instructions"] as? String == "Generate only the requested HoverPocket Pocket App DSL document. Do not call tools. Return only one JSON object that satisfies the supplied output schema." else {
            throw PocketAppGenerationError.generatorUnavailable
        }
    }
}
