import Foundation
import CoreFoundation

enum PocketSurfaceRuntimeError: Error, Equatable, CustomStringConvertible {
    case invalid(String)

    var description: String {
        switch self {
        case .invalid(let path):
            return path
        }
    }
}

enum PocketJSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([PocketJSONValue])
    case object([String: PocketJSONValue])

    init(any value: Any, path: String, depth: Int = 0) throws {
        guard depth <= 16 else {
            throw PocketSurfaceRuntimeError.invalid("\(path):json_depth")
        }

        switch value {
        case is NSNull:
            self = .null
        case let value as Bool:
            self = .bool(value)
        case let value as NSNumber:
            let number = value.doubleValue
            guard number.isFinite else {
                throw PocketSurfaceRuntimeError.invalid("\(path):number")
            }
            self = .number(number)
        case let value as String:
            self = .string(value)
        case let value as [Any]:
            guard value.count <= 256 else {
                throw PocketSurfaceRuntimeError.invalid("\(path):array_size")
            }
            self = .array(try value.enumerated().map {
                try PocketJSONValue(any: $0.element, path: "\(path)[\($0.offset)]", depth: depth + 1)
            })
        case let value as [String: Any]:
            guard value.count <= 128 else {
                throw PocketSurfaceRuntimeError.invalid("\(path):object_size")
            }
            var object: [String: PocketJSONValue] = [:]
            for key in value.keys.sorted() {
                guard key.unicodeScalars.count <= 128, let child = value[key] else {
                    throw PocketSurfaceRuntimeError.invalid("\(path):object_key")
                }
                object[key] = try PocketJSONValue(any: child, path: "\(path).\(key)", depth: depth + 1)
            }
            self = .object(object)
        default:
            throw PocketSurfaceRuntimeError.invalid("\(path):json_type")
        }
    }

    var foundationValue: Any {
        switch self {
        case .null:
            return NSNull()
        case .bool(let value):
            return value
        case .number(let value):
            return value
        case .string(let value):
            return value
        case .array(let values):
            return values.map(\.foundationValue)
        case .object(let object):
            return object.mapValues(\.foundationValue)
        }
    }
}

struct PocketSurfaceRenderNode: Equatable, Sendable {
    let type: String
    let properties: [String: PocketJSONValue]
    let children: [PocketSurfaceRenderNode]

    fileprivate var foundationValue: [String: Any] {
        var value = properties.mapValues(\.foundationValue)
        value["type"] = type
        if !children.isEmpty {
            value["children"] = children.map(\.foundationValue)
        }
        return value
    }
}

struct PocketSurfaceDocument: Equatable, Sendable {
    let id: String
    let root: PocketSurfaceRenderNode
    let nodeCount: Int
    let maximumDepth: Int

    func canonicalRenderModelData() throws -> Data {
        try JSONSerialization.data(
            withJSONObject: [
                "hostRegion": "provider_host",
                "root": root.foundationValue,
                "surfaceId": id,
                "surfaceVersion": 1
            ],
            options: [.sortedKeys]
        )
    }
}

struct PocketSurfaceRuntime {
    static let maximumDocumentBytes = 256 * 1024
    static let maximumNodes = 256
    static let maximumDepth = 8

    let knownQueries: Set<String>
    let knownWorkflows: Set<String>

    init(knownQueries: Set<String>, knownWorkflows: Set<String>) {
        self.knownQueries = knownQueries
        self.knownWorkflows = knownWorkflows
    }

    func load(data: Data) throws -> PocketSurfaceDocument {
        guard data.count <= Self.maximumDocumentBytes else {
            throw PocketSurfaceRuntimeError.invalid("$:document_size")
        }
        let json = try JSONSerialization.jsonObject(with: data)
        let rootObject = try object(json, path: "$")
        try exactKeys(
            rootObject,
            required: ["$schema", "surfaceVersion", "id", "hostBoundary", "root"],
            optional: [],
            path: "$"
        )
        try require(string(rootObject["$schema"], path: "$.$schema") == "hoverpocket://schemas/pocket-surface/v1", "$.$schema")
        try require(integer(rootObject["surfaceVersion"], path: "$.surfaceVersion") == 1, "$.surfaceVersion")
        let id = try string(rootObject["id"], path: "$.id")
        try require(matches(id, "^[A-Za-z][A-Za-z0-9_-]{0,63}$"), "$.id")
        try validateHostBoundary(rootObject["hostBoundary"])

        var nodeCount = 0
        var maximumDepth = 0
        let root = try validateNode(
            rootObject["root"],
            path: "$.root",
            depth: 1,
            nodeCount: &nodeCount,
            maximumDepth: &maximumDepth
        )
        return PocketSurfaceDocument(id: id, root: root, nodeCount: nodeCount, maximumDepth: maximumDepth)
    }

    private func validateHostBoundary(_ value: Any?) throws {
        let boundary = try object(value, path: "$.hostBoundary")
        try exactKeys(
            boundary,
            required: ["region", "mayRenderHeader", "mayRenderVoiceLane", "mayRenderApproval", "mayRenderReceipt"],
            optional: [],
            path: "$.hostBoundary"
        )
        try require(string(boundary["region"], path: "$.hostBoundary.region") == "provider_host", "$.hostBoundary.region")
        for key in ["mayRenderHeader", "mayRenderVoiceLane", "mayRenderApproval", "mayRenderReceipt"] {
            try require(boolean(boundary[key], path: "$.hostBoundary.\(key)") == false, "$.hostBoundary.\(key)")
        }
    }

    private func validateNode(
        _ value: Any?,
        path: String,
        depth: Int,
        nodeCount: inout Int,
        maximumDepth: inout Int
    ) throws -> PocketSurfaceRenderNode {
        try require(depth <= Self.maximumDepth, "\(path):depth")
        nodeCount += 1
        try require(nodeCount <= Self.maximumNodes, "\(path):node_count")
        maximumDepth = max(maximumDepth, depth)

        let node = try object(value, path: path)
        let type = try string(node["type"], path: "\(path).type")
        switch type {
        case "stack":
            try exactKeys(node, required: ["type", "axis", "children"], optional: ["spacing"], path: path)
            let axis = try string(node["axis"], path: "\(path).axis")
            try require(["vertical", "horizontal"].contains(axis), "\(path).axis")
            let spacing = try optionalInteger(node["spacing"], defaultValue: 0, path: "\(path).spacing")
            try require((0...64).contains(spacing), "\(path).spacing")
            let children = try validateChildren(node["children"], path: path, depth: depth, nodeCount: &nodeCount, maximumDepth: &maximumDepth)
            return renderNode(type, ["axis": .string(axis), "spacing": .number(Double(spacing))], children)
        case "grid":
            try exactKeys(node, required: ["type", "columns", "children"], optional: ["gap"], path: path)
            let columns = try integer(node["columns"], path: "\(path).columns")
            let gap = try optionalInteger(node["gap"], defaultValue: 0, path: "\(path).gap")
            try require((1...12).contains(columns), "\(path).columns")
            try require((0...64).contains(gap), "\(path).gap")
            let children = try validateChildren(node["children"], path: path, depth: depth, nodeCount: &nodeCount, maximumDepth: &maximumDepth)
            return renderNode(type, ["columns": .number(Double(columns)), "gap": .number(Double(gap))], children)
        case "text":
            try exactKeys(node, required: ["type", "style", "value"], optional: [], path: path)
            let style = try string(node["style"], path: "\(path).style")
            let text = try boundedString(node["value"], range: 0...2000, path: "\(path).value")
            try require(["title", "body", "caption", "monospace"].contains(style), "\(path).style")
            return renderNode(type, ["style": .string(style), "value": .string(text)])
        case "image":
            try exactKeys(node, required: ["type", "assetRef", "alt"], optional: [], path: path)
            let assetRef = try boundedString(node["assetRef"], range: 1...240, path: "\(path).assetRef")
            let alt = try boundedString(node["alt"], range: 1...240, path: "\(path).alt")
            try require(validAssetReference(assetRef), "\(path).assetRef")
            return renderNode(type, ["alt": .string(alt), "assetRef": .string(assetRef)])
        case "button":
            try exactKeys(node, required: ["type", "label", "workflow"], optional: [], path: path)
            let label = try boundedString(node["label"], range: 1...120, path: "\(path).label")
            let workflow = try string(node["workflow"], path: "\(path).workflow")
            try require(matches(workflow, "^[A-Za-z][A-Za-z0-9_-]{0,63}$"), "\(path).workflow")
            try require(knownWorkflows.contains(workflow), "\(path).workflow:unknown")
            return renderNode(type, ["label": .string(label), "workflow": .string(workflow)])
        case "textField":
            try exactKeys(node, required: ["type", "label", "value", "maxLength"], optional: [], path: path)
            let label = try boundedString(node["label"], range: 1...120, path: "\(path).label")
            let binding = try binding(node["value"], inputAllowed: true, stateAllowed: true, path: "\(path).value")
            let maxLength = try integer(node["maxLength"], path: "\(path).maxLength")
            try require((1...10_000).contains(maxLength), "\(path).maxLength")
            return renderNode(type, ["label": .string(label), "maxLength": .number(Double(maxLength)), "value": .string(binding)])
        case "toggle":
            try exactKeys(node, required: ["type", "label", "value"], optional: [], path: path)
            let label = try boundedString(node["label"], range: 1...120, path: "\(path).label")
            let binding = try binding(node["value"], inputAllowed: true, stateAllowed: true, path: "\(path).value")
            return renderNode(type, ["label": .string(label), "value": .string(binding)])
        case "picker":
            return try validatePicker(node, path: path)
        case "calendarEventPicker":
            try exactKeys(node, required: ["type", "items", "selection"], optional: ["titleTarget"], path: path)
            let items = try queryBinding(node["items"], path: "\(path).items")
            let selection = try binding(node["selection"], inputAllowed: false, stateAllowed: true, path: "\(path).selection")
            var properties: [String: PocketJSONValue] = ["items": items, "selection": .string(selection)]
            if let titleTarget = node["titleTarget"] {
                properties["titleTarget"] = .string(try binding(
                    titleTarget,
                    inputAllowed: true,
                    stateAllowed: false,
                    path: "\(path).titleTarget"
                ))
            }
            return renderNode(type, properties)
        case "durationPicker":
            try exactKeys(node, required: ["type", "value", "min", "max"], optional: ["default"], path: path)
            let binding = try binding(node["value"], inputAllowed: true, stateAllowed: false, path: "\(path).value")
            let minimum = try integer(node["min"], path: "\(path).min")
            let maximum = try integer(node["max"], path: "\(path).max")
            let defaultValue = try optionalInteger(node["default"], defaultValue: minimum, path: "\(path).default")
            try require(
                (1...86_400).contains(minimum)
                    && (1...86_400).contains(maximum)
                    && minimum <= defaultValue
                    && defaultValue <= maximum,
                "\(path):duration_range"
            )
            return renderNode(type, [
                "default": .number(Double(defaultValue)),
                "max": .number(Double(maximum)),
                "min": .number(Double(minimum)),
                "value": .string(binding)
            ])
        case "status":
            try exactKeys(node, required: ["type", "value", "tone"], optional: [], path: path)
            let text = try boundedString(node["value"], range: 0...1000, path: "\(path).value")
            let tone = try string(node["tone"], path: "\(path).tone")
            try require(["neutral", "success", "warning", "error"].contains(tone), "\(path).tone")
            return renderNode(type, ["tone": .string(tone), "value": .string(text)])
        default:
            throw PocketSurfaceRuntimeError.invalid("\(path).type:unknown")
        }
    }

    private func validatePicker(_ node: [String: Any], path: String) throws -> PocketSurfaceRenderNode {
        try exactKeys(node, required: ["type", "label", "options", "value"], optional: [], path: path)
        let label = try boundedString(node["label"], range: 1...120, path: "\(path).label")
        let binding = try binding(node["value"], inputAllowed: true, stateAllowed: true, path: "\(path).value")
        guard let optionValues = node["options"] as? [Any], (1...64).contains(optionValues.count) else {
            throw PocketSurfaceRuntimeError.invalid("\(path).options")
        }
        let options = try optionValues.enumerated().map { index, raw -> PocketJSONValue in
            let optionPath = "\(path).options[\(index)]"
            let option = try object(raw, path: optionPath)
            try exactKeys(option, required: ["label", "value"], optional: [], path: optionPath)
            return .object([
                "label": .string(try boundedString(option["label"], range: 1...120, path: "\(optionPath).label")),
                "value": .string(try boundedString(option["value"], range: 0...120, path: "\(optionPath).value"))
            ])
        }
        return renderNode("picker", ["label": .string(label), "options": .array(options), "value": .string(binding)])
    }

    private func queryBinding(_ value: Any?, path: String) throws -> PocketJSONValue {
        let binding = try object(value, path: path)
        try exactKeys(binding, required: ["query", "arguments"], optional: [], path: path)
        let query = try boundedString(binding["query"], range: 1...160, path: "\(path).query")
        try require(matches(query, "^[a-z][a-z0-9]*(?:\\.[a-z][a-z0-9_]*){2,}@[1-9][0-9]*$"), "\(path).query")
        try require(knownQueries.contains(query), "\(path).query:unknown")
        let arguments = try object(binding["arguments"], path: "\(path).arguments")
        try require(
            arguments.count <= 64 && arguments.keys.allSatisfy { $0.unicodeScalars.count <= 64 },
            "\(path).arguments"
        )
        return .object([
            "arguments": try PocketJSONValue(any: arguments, path: "\(path).arguments"),
            "query": .string(query)
        ])
    }

    private func validateChildren(
        _ value: Any?,
        path: String,
        depth: Int,
        nodeCount: inout Int,
        maximumDepth: inout Int
    ) throws -> [PocketSurfaceRenderNode] {
        guard let children = value as? [Any], children.count <= 64 else {
            throw PocketSurfaceRuntimeError.invalid("\(path).children")
        }
        return try children.enumerated().map { index, child in
            try validateNode(
                child,
                path: "\(path).children[\(index)]",
                depth: depth + 1,
                nodeCount: &nodeCount,
                maximumDepth: &maximumDepth
            )
        }
    }

    private func renderNode(
        _ type: String,
        _ properties: [String: PocketJSONValue],
        _ children: [PocketSurfaceRenderNode] = []
    ) -> PocketSurfaceRenderNode {
        PocketSurfaceRenderNode(type: type, properties: properties, children: children)
    }

    private func object(_ value: Any?, path: String) throws -> [String: Any] {
        guard let value = value as? [String: Any] else {
            throw PocketSurfaceRuntimeError.invalid("\(path):object")
        }
        return value
    }

    private func string(_ value: Any?, path: String) throws -> String {
        guard let value = value as? String else {
            throw PocketSurfaceRuntimeError.invalid("\(path):string")
        }
        return value
    }

    private func boundedString(_ value: Any?, range: ClosedRange<Int>, path: String) throws -> String {
        let value = try string(value, path: path)
        try require(range.contains(value.unicodeScalars.count), path)
        return value
    }

    private func boolean(_ value: Any?, path: String) throws -> Bool {
        guard let value = value as? Bool else {
            throw PocketSurfaceRuntimeError.invalid("\(path):boolean")
        }
        return value
    }

    private func integer(_ value: Any?, path: String) throws -> Int {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else {
            throw PocketSurfaceRuntimeError.invalid("\(path):integer")
        }
        let double = number.doubleValue
        guard double.isFinite, double.rounded() == double, double >= Double(Int.min), double <= Double(Int.max) else {
            throw PocketSurfaceRuntimeError.invalid("\(path):integer")
        }
        return Int(double)
    }

    private func optionalInteger(_ value: Any?, defaultValue: Int, path: String) throws -> Int {
        guard let value else { return defaultValue }
        return try integer(value, path: path)
    }

    private func binding(
        _ value: Any?,
        inputAllowed: Bool,
        stateAllowed: Bool,
        path: String
    ) throws -> String {
        let value = try boundedString(value, range: 1...128, path: path)
        let allowed = (inputAllowed && matches(value, "^\\$input\\.[A-Za-z][A-Za-z0-9_]*$"))
            || (stateAllowed && matches(value, "^\\$state\\.[A-Za-z][A-Za-z0-9_]*$"))
        try require(allowed, path)
        return value
    }

    private func exactKeys(
        _ object: [String: Any],
        required: Set<String>,
        optional: Set<String>,
        path: String
    ) throws {
        let keys = Set(object.keys)
        try require(required.isSubset(of: keys), "\(path):missing_key")
        try require(keys.isSubset(of: required.union(optional)), "\(path):unknown_key")
    }

    private func matches(_ value: String, _ pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
    }

    private func validAssetReference(_ value: String) -> Bool {
        let prefix = "asset://"
        guard value.hasPrefix(prefix) else { return false }
        let relativePath = String(value.dropFirst(prefix.count))
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty else { return false }
        return components.allSatisfy { component in
            guard !component.isEmpty, component != ".", component != ".." else { return false }
            return component.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil
        }
    }

    private func require(_ condition: @autoclosure () throws -> Bool, _ path: String) throws {
        guard try condition() else {
            throw PocketSurfaceRuntimeError.invalid(path)
        }
    }
}
