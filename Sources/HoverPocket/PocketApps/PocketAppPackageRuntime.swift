import CryptoKit
import CoreFoundation
import Foundation

enum PocketAppPackageError: Error, Equatable, CustomStringConvertible {
    case invalid(String)

    var description: String {
        switch self {
        case .invalid(let path): path
        }
    }
}

struct PocketAppRequestedCapability: Equatable, Sendable {
    let key: PocketCapabilityKey
    let scope: PocketJSONValue?
    let effect: CapabilityEffect
    let permissions: Set<String>
}

struct PocketAppManifestDocument: Equatable, Sendable {
    let id: String
    let name: String
    let version: String
    let minimumHostVersion: String
    let intentPath: String
    let stateSchemaPath: String
    let stateStore: String
    let surfaces: [String: String]
    let requestedCapabilities: [PocketAppRequestedCapability]
    let workflows: [String: String]
    let tests: [String]
}

struct PocketAppWorkflowStep: Equatable, Sendable {
    let id: String
    let capability: PocketCapabilityKey
    let arguments: [String: PocketJSONValue]
    let dependencies: [String]
}

struct PocketAppWorkflowDocument: Equatable, Sendable {
    let id: String
    let inputs: [String: String]
    let approvalMode: String
    let approvalGroup: String
    let steps: [PocketAppWorkflowStep]
    let partialFailureMode: String
    let timeoutSeconds: Int
    let requiredPermissions: Set<String>
}

struct PocketAppPackage: Equatable, Sendable {
    let rootDirectory: URL
    let manifest: PocketAppManifestDocument
    let manifestDigest: String
    let intent: String
    let stateSchemaDigest: String
    let statePropertyNames: Set<String>
    let statePropertyTypes: [String: Set<String>]
    let surfaces: [String: PocketSurfaceDocument]
    let workflows: [String: PocketAppWorkflowDocument]
    let testCases: [String: String]
}

struct PocketAppPackageRuntime {
    static let maximumFiles = 128
    static let maximumFileBytes = 1 * 1_024 * 1_024
    static let maximumPackageBytes = 8 * 1_024 * 1_024

    private let descriptors: [PocketCapabilityKey: PocketCapabilityDescriptor]

    init(descriptors: [PocketCapabilityDescriptor] = PocketCapabilityDescriptors.builtIn) {
        self.descriptors = Dictionary(uniqueKeysWithValues: descriptors.map { ($0.key, $0) })
    }

    func load(directory: URL) throws -> PocketAppPackage {
        try load(snapshot: PocketAppFileSnapshot.capture(directory: directory))
    }

    func load(snapshot: PocketAppFileSnapshot) throws -> PocketAppPackage {
        let root = snapshot.rootDirectory
        let packageFiles = snapshot.files
        guard let manifestData = packageFiles["manifest.json"] else {
            throw PocketAppPackageError.invalid("$:package_files")
        }
        let manifestObject = try jsonObject(manifestData, path: "$.manifest")
        let manifest = try parseManifest(manifestObject)

        var expectedFiles: Set<String> = ["manifest.json", manifest.intentPath, manifest.stateSchemaPath]
        expectedFiles.formUnion(manifest.surfaces.values)
        expectedFiles.formUnion(manifest.workflows.values)
        expectedFiles.formUnion(manifest.tests)
        try require(Set(packageFiles.keys) == expectedFiles, "$:package_files")
        let manifestDigest = packageDigest(packageFiles)

        let intentData = try packageData(manifest.intentPath, files: packageFiles)
        guard let intent = String(data: intentData, encoding: .utf8),
              !intent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              intent.unicodeScalars.count <= 20_000 else {
            throw PocketAppPackageError.invalid("$.intent")
        }

        let stateData = try packageData(manifest.stateSchemaPath, files: packageFiles)
        let stateSchemaDigest = "sha256:" + SHA256.hash(data: stateData).map { String(format: "%02x", $0) }.joined()
        let statePropertyTypes = try validateStateSchema(jsonObject(stateData, path: "$.state.schema"))
        let statePropertyNames = Set(statePropertyTypes.keys)

        let requestedScopes = Dictionary(
            uniqueKeysWithValues: manifest.requestedCapabilities.map { ($0.key, $0.scope) }
        )
        let readableQueries = Set(manifest.requestedCapabilities.compactMap { request -> String? in
            guard descriptors[request.key]?.effect == .privateRead else { return nil }
            return "\(request.key.id)@\(request.key.version)"
        })
        let surfaceRuntime = PocketSurfaceRuntime(
            knownQueries: readableQueries,
            knownWorkflows: Set(manifest.workflows.keys)
        )
        var surfaces: [String: PocketSurfaceDocument] = [:]
        for (id, path) in manifest.surfaces.sorted(by: { $0.key < $1.key }) {
            let document = try surfaceRuntime.load(data: packageData(path, files: packageFiles))
            try require(document.id == id, "$.surfaces.\(id):id")
            surfaces[id] = document
        }

        var workflows: [String: PocketAppWorkflowDocument] = [:]
        for (id, path) in manifest.workflows.sorted(by: { $0.key < $1.key }) {
            let workflow = try parseWorkflow(
                jsonObject(try packageData(path, files: packageFiles), path: "$.workflows.\(id)"),
                requestedScopes: requestedScopes
            )
            try require(workflow.id == id, "$.workflows.\(id):id")
            for (index, step) in workflow.steps.enumerated() {
                try require(
                    PocketAppWorkflowPresentationPolicy.supports(step.capability),
                    "$.workflows.\(id).steps[\(index)]:presentation"
                )
            }
            workflows[id] = workflow
        }

        var workflowInputTypes: [String: String] = [:]
        for workflow in workflows.values {
            for (name, type) in workflow.inputs {
                if let existingType = workflowInputTypes[name] {
                    try require(existingType == type, "$.workflows:input_type_conflict")
                } else {
                    workflowInputTypes[name] = type
                }
            }
        }
        for surface in surfaces.values {
            var boundNames: Set<String> = []
            try validateBindings(
                node: surface.root,
                inputTypes: workflowInputTypes,
                stateTypes: statePropertyTypes,
                boundNames: &boundNames,
                path: "$.surfaces.\(surface.id).root"
            )
            try validateSurfaceScopes(node: surface.root, requestedScopes: requestedScopes, path: "$.surfaces.\(surface.id).root")
            for workflowID in referencedWorkflows(node: surface.root) {
                guard let workflow = workflows[workflowID] else {
                    throw PocketAppPackageError.invalid("$.surfaces.\(surface.id):workflow")
                }
                try require(
                    Set(workflow.inputs.keys).isSubset(of: boundNames),
                    "$.surfaces.\(surface.id):unbound_workflow_input"
                )
            }
        }

        var testCases: [String: String] = [:]
        for path in manifest.tests {
            let object = try jsonObject(try packageData(path, files: packageFiles), path: "$.tests")
            try exactKeys(object, required: ["case", "expected"], optional: [], path: "$.tests")
            let name = try boundedString(object["case"], range: 1...120, path: "$.tests.case")
            let expected = try boundedString(object["expected"], range: 1...32, path: "$.tests.expected")
            try require(PocketAppStagingTestRunner.supportedCaseIDs.contains(name), "$.tests.case:unsupported")
            try require(["pass", "reject"].contains(expected), "$.tests.expected")
            try require(testCases[name] == nil, "$.tests.case:duplicate")
            testCases[name] = expected
        }

        return PocketAppPackage(
            rootDirectory: root,
            manifest: manifest,
            manifestDigest: manifestDigest,
            intent: intent,
            stateSchemaDigest: stateSchemaDigest,
            statePropertyNames: statePropertyNames,
            statePropertyTypes: statePropertyTypes,
            surfaces: surfaces,
            workflows: workflows,
            testCases: testCases
        )
    }

    private func parseManifest(_ object: [String: Any]) throws -> PocketAppManifestDocument {
        try exactKeys(
            object,
            required: ["$schema", "apiVersion", "id", "name", "version", "minHostVersion", "intent", "state", "surfaces", "requestedCapabilities", "workflows", "tests", "workspace"],
            optional: [],
            path: "$.manifest"
        )
        try require(try string(object["$schema"], path: "$.manifest.$schema") == "hoverpocket://schemas/pocket-app/v1", "$.manifest.$schema")
        try require(try string(object["apiVersion"], path: "$.manifest.apiVersion") == "hoverpocket.app/v1", "$.manifest.apiVersion")
        let id = try boundedString(object["id"], range: 1...160, path: "$.manifest.id")
        try require(matches(id, "^[a-z][a-z0-9]*(?:\\.[a-z0-9][a-z0-9-]*){2,}$"), "$.manifest.id")
        let name = try boundedString(object["name"], range: 1...120, path: "$.manifest.name")
        let version = try semanticVersion(object["version"], path: "$.manifest.version")
        let minimumHostVersion = try semanticVersion(object["minHostVersion"], path: "$.manifest.minHostVersion")
        let intentPath = try safePath(object["intent"], path: "$.manifest.intent")

        let state = try dictionary(object["state"], path: "$.manifest.state")
        try exactKeys(state, required: ["schema", "store"], optional: [], path: "$.manifest.state")
        let stateSchemaPath = try safePath(state["schema"], path: "$.manifest.state.schema")
        let stateStore = try boundedString(state["store"], range: 1...240, path: "$.manifest.state.store")
        try require(stateStore == "user-data://\(id)", "$.manifest.state.store")

        let surfaceItems = try array(object["surfaces"], path: "$.manifest.surfaces")
        try require((1...16).contains(surfaceItems.count), "$.manifest.surfaces")
        var surfaces: [String: String] = [:]
        for (index, item) in surfaceItems.enumerated() {
            let surface = try dictionary(item, path: "$.manifest.surfaces[\(index)]")
            try exactKeys(surface, required: ["id", "kind", "source"], optional: [], path: "$.manifest.surfaces[\(index)]")
            let surfaceID = try identifier(surface["id"], path: "$.manifest.surfaces[\(index)].id")
            try require(try string(surface["kind"], path: "$.manifest.surfaces[\(index)].kind") == "declarative", "$.manifest.surfaces[\(index)].kind")
            let source = try safePath(surface["source"], path: "$.manifest.surfaces[\(index)].source")
            try require(surfaces[surfaceID] == nil, "$.manifest.surfaces:duplicate")
            surfaces[surfaceID] = source
        }

        let capabilityItems = try array(object["requestedCapabilities"], path: "$.manifest.requestedCapabilities")
        try require(capabilityItems.count <= 64, "$.manifest.requestedCapabilities")
        var capabilities: [PocketAppRequestedCapability] = []
        var capabilityKeys: Set<PocketCapabilityKey> = []
        for (index, item) in capabilityItems.enumerated() {
            let request = try dictionary(item, path: "$.manifest.requestedCapabilities[\(index)]")
            try exactKeys(request, required: ["id", "version"], optional: ["scope"], path: "$.manifest.requestedCapabilities[\(index)]")
            let capabilityID = try boundedString(request["id"], range: 1...128, path: "$.manifest.requestedCapabilities[\(index)].id")
            let capabilityVersion = try integer(request["version"], path: "$.manifest.requestedCapabilities[\(index)].version")
            let key = PocketCapabilityKey(id: capabilityID, version: capabilityVersion)
            guard let descriptor = descriptors[key], descriptor.approvalPolicy != .runtimeProhibited else {
                throw PocketAppPackageError.invalid("$.manifest.requestedCapabilities[\(index)]:unknown")
            }
            try require(capabilityKeys.insert(key).inserted, "$.manifest.requestedCapabilities:duplicate")
            let scope = try request["scope"].map { try PocketJSONValue(any: $0, path: "$.manifest.requestedCapabilities[\(index)].scope") }
            try validateScope(scope, key: key, path: "$.manifest.requestedCapabilities[\(index)].scope")
            capabilities.append(PocketAppRequestedCapability(
                key: key,
                scope: scope,
                effect: descriptor.effect,
                permissions: descriptor.permissions
            ))
        }

        let workflowObject = try dictionary(object["workflows"], path: "$.manifest.workflows")
        try require(workflowObject.count <= 32, "$.manifest.workflows")
        var workflows: [String: String] = [:]
        for key in workflowObject.keys.sorted() {
            let workflowID = try identifier(key, path: "$.manifest.workflows")
            workflows[workflowID] = try safePath(workflowObject[key], path: "$.manifest.workflows.\(key)")
        }

        let testItems = try array(object["tests"], path: "$.manifest.tests")
        try require(testItems.count <= 128, "$.manifest.tests")
        let tests = try testItems.enumerated().map { try safePath($0.element, path: "$.manifest.tests[\($0.offset)]") }
        try require(Set(tests).count == tests.count, "$.manifest.tests:duplicate")

        let workspace = try dictionary(object["workspace"], path: "$.manifest.workspace")
        try exactKeys(workspace, required: ["ownership", "definitionRoot", "dataRoot", "secrets", "exportable", "deletable", "rollback"], optional: [], path: "$.manifest.workspace")
        try require(try string(workspace["ownership"], path: "$.manifest.workspace.ownership") == "user", "$.manifest.workspace.ownership")
        try require(try string(workspace["definitionRoot"], path: "$.manifest.workspace.definitionRoot") == "app_definition", "$.manifest.workspace.definitionRoot")
        try require(try string(workspace["dataRoot"], path: "$.manifest.workspace.dataRoot") == "separate_user_data", "$.manifest.workspace.dataRoot")
        try require(try string(workspace["secrets"], path: "$.manifest.workspace.secrets") == "credential_store_only", "$.manifest.workspace.secrets")
        try require(try boolean(workspace["exportable"], path: "$.manifest.workspace.exportable"), "$.manifest.workspace.exportable")
        try require(try boolean(workspace["deletable"], path: "$.manifest.workspace.deletable"), "$.manifest.workspace.deletable")
        try require(try string(workspace["rollback"], path: "$.manifest.workspace.rollback") == "versioned_snapshot", "$.manifest.workspace.rollback")

        return PocketAppManifestDocument(
            id: id,
            name: name,
            version: version,
            minimumHostVersion: minimumHostVersion,
            intentPath: intentPath,
            stateSchemaPath: stateSchemaPath,
            stateStore: stateStore,
            surfaces: surfaces,
            requestedCapabilities: capabilities,
            workflows: workflows,
            tests: tests
        )
    }

    private func parseWorkflow(
        _ object: [String: Any],
        requestedScopes: [PocketCapabilityKey: PocketJSONValue?]
    ) throws -> PocketAppWorkflowDocument {
        try exactKeys(object, required: ["$schema", "workflowVersion", "id", "inputs", "approval", "steps", "onPartialFailure", "limits"], optional: [], path: "$.workflow")
        try require(try string(object["$schema"], path: "$.workflow.$schema") == "hoverpocket://schemas/pocket-workflow/v1", "$.workflow.$schema")
        try require(try integer(object["workflowVersion"], path: "$.workflow.workflowVersion") == 1, "$.workflow.workflowVersion")
        let id = try identifier(object["id"], path: "$.workflow.id")
        let inputObject = try dictionary(object["inputs"], path: "$.workflow.inputs")
        try require(inputObject.count <= 64, "$.workflow.inputs")
        var inputs: [String: String] = [:]
        for name in inputObject.keys.sorted() {
            let key = try identifier(name, path: "$.workflow.inputs")
            let type = try string(inputObject[name], path: "$.workflow.inputs.\(name)")
            try require(["string", "integer", "number", "boolean", "date-time", "entity-ref"].contains(type), "$.workflow.inputs.\(name)")
            inputs[key] = type
        }

        let approval = try dictionary(object["approval"], path: "$.workflow.approval")
        try exactKeys(approval, required: ["mode", "group"], optional: [], path: "$.workflow.approval")
        let approvalMode = try string(approval["mode"], path: "$.workflow.approval.mode")
        let approvalGroup = try string(approval["group"], path: "$.workflow.approval.group")
        try require(["none", "before_writes", "per_step"].contains(approvalMode), "$.workflow.approval.mode")
        try require(["none", "all_writes", "step"].contains(approvalGroup), "$.workflow.approval.group")
        try require((approvalMode == "none") == (approvalGroup == "none"), "$.workflow.approval")

        let limits = try dictionary(object["limits"], path: "$.workflow.limits")
        try exactKeys(limits, required: ["maxSteps", "maxDepth", "timeoutSeconds"], optional: [], path: "$.workflow.limits")
        let maximumSteps = try integer(limits["maxSteps"], path: "$.workflow.limits.maxSteps")
        let maximumDepth = try integer(limits["maxDepth"], path: "$.workflow.limits.maxDepth")
        let timeoutSeconds = try integer(limits["timeoutSeconds"], path: "$.workflow.limits.timeoutSeconds")
        try require((1...32).contains(maximumSteps) && (1...8).contains(maximumDepth) && (1...300).contains(timeoutSeconds), "$.workflow.limits")

        let stepItems = try array(object["steps"], path: "$.workflow.steps")
        try require(!stepItems.isEmpty && stepItems.count <= maximumSteps, "$.workflow.steps")
        var seen: Set<String> = []
        var steps: [PocketAppWorkflowStep] = []
        var requiredPermissions: Set<String> = []
        var hasWrite = false
        for (index, item) in stepItems.enumerated() {
            let step = try dictionary(item, path: "$.workflow.steps[\(index)]")
            try exactKeys(step, required: ["id", "use", "with", "dependsOn"], optional: [], path: "$.workflow.steps[\(index)]")
            let stepID = try identifier(step["id"], path: "$.workflow.steps[\(index)].id")
            try require(seen.insert(stepID).inserted, "$.workflow.steps:duplicate")
            let use = try boundedString(step["use"], range: 3...160, path: "$.workflow.steps[\(index)].use")
            let capability = try capabilityKey(use, path: "$.workflow.steps[\(index)].use")
            try require(requestedScopes.keys.contains(capability), "$.workflow.steps[\(index)].use:undeclared")
            guard let descriptor = descriptors[capability], descriptor.approvalPolicy != .runtimeProhibited else {
                throw PocketAppPackageError.invalid("$.workflow.steps[\(index)].use:unknown")
            }
            hasWrite = hasWrite || descriptor.effect.isWrite
            requiredPermissions.formUnion(descriptor.permissions)
            let argumentObject = try dictionary(step["with"], path: "$.workflow.steps[\(index)].with")
            try require(argumentObject.count <= 64, "$.workflow.steps[\(index)].with")
            var arguments: [String: PocketJSONValue] = [:]
            for key in argumentObject.keys.sorted() {
                try require(matches(key, "^[A-Za-z][A-Za-z0-9_]{0,63}$"), "$.workflow.steps[\(index)].with")
                guard let rawValue = argumentObject[key] else {
                    throw PocketAppPackageError.invalid("$.workflow.steps[\(index)].with.\(key)")
                }
                let value = try PocketJSONValue(any: rawValue, path: "$.workflow.steps[\(index)].with.\(key)")
                try validateWorkflowBinding(value, inputs: Set(inputs.keys), path: "$.workflow.steps[\(index)].with.\(key)")
                arguments[key] = value
            }
            try validateCapabilityScope(
                arguments: arguments,
                scope: requestedScopes[capability] ?? nil,
                key: capability,
                path: "$.workflow.steps[\(index)].with"
            )
            let dependencies = try array(step["dependsOn"], path: "$.workflow.steps[\(index)].dependsOn").enumerated().map {
                try identifier($0.element, path: "$.workflow.steps[\(index)].dependsOn[\($0.offset)]")
            }
            try require(Set(dependencies).count == dependencies.count && dependencies.allSatisfy(seen.contains) && !dependencies.contains(stepID), "$.workflow.steps[\(index)].dependsOn")
            steps.append(PocketAppWorkflowStep(id: stepID, capability: capability, arguments: arguments, dependencies: dependencies))
        }
        try require(!hasWrite || approvalMode != "none", "$.workflow.approval:writes")
        try require(!(steps.count > 1 && steps.contains { descriptors[$0.capability]?.approvalPolicy == .strongPerCall }), "$.workflow.steps:strong_per_call")

        let partial = try dictionary(object["onPartialFailure"], path: "$.workflow.onPartialFailure")
        try exactKeys(partial, required: ["mode", "presentReceipt"], optional: [], path: "$.workflow.onPartialFailure")
        let partialMode = try string(partial["mode"], path: "$.workflow.onPartialFailure.mode")
        try require(["stop", "continue", "compensate_if_available"].contains(partialMode), "$.workflow.onPartialFailure.mode")
        try require(try boolean(partial["presentReceipt"], path: "$.workflow.onPartialFailure.presentReceipt"), "$.workflow.onPartialFailure.presentReceipt")

        return PocketAppWorkflowDocument(
            id: id,
            inputs: inputs,
            approvalMode: approvalMode,
            approvalGroup: approvalGroup,
            steps: steps,
            partialFailureMode: partialMode,
            timeoutSeconds: timeoutSeconds,
            requiredPermissions: requiredPermissions
        )
    }

    private func validateStateSchema(_ object: [String: Any]) throws -> [String: Set<String>] {
        try exactKeys(object, required: ["type", "properties", "additionalProperties"], optional: ["$schema", "required"], path: "$.state.schema")
        if let schema = object["$schema"] {
            try require(try string(schema, path: "$.state.schema.$schema") == "https://json-schema.org/draft/2020-12/schema", "$.state.schema.$schema")
        }
        try require(try string(object["type"], path: "$.state.schema.type") == "object", "$.state.schema.type")
        try require(try boolean(object["additionalProperties"], path: "$.state.schema.additionalProperties") == false, "$.state.schema.additionalProperties")
        let properties = try dictionary(object["properties"], path: "$.state.schema.properties")
        try require(properties.count <= 128, "$.state.schema.properties")
        var propertyTypes: [String: Set<String>] = [:]
        for (name, value) in properties {
            try require(matches(name, "^[A-Za-z][A-Za-z0-9_]{0,63}$"), "$.state.schema.properties")
            let property = try dictionary(value, path: "$.state.schema.properties.\(name)")
            try exactKeys(property, required: ["type"], optional: ["format", "maxLength"], path: "$.state.schema.properties.\(name)")
            let types: [String]
            if let text = property["type"] as? String {
                types = [text]
            } else {
                types = try array(property["type"], path: "$.state.schema.properties.\(name).type").map { try string($0, path: "$.state.schema.properties.\(name).type") }
            }
            try require(!types.isEmpty && Set(types).count == types.count && types.allSatisfy { ["string", "integer", "number", "boolean", "null"].contains($0) }, "$.state.schema.properties.\(name).type")
            propertyTypes[name] = Set(types)
            if let format = property["format"] {
                try require(try string(format, path: "$.state.schema.properties.\(name).format") == "date", "$.state.schema.properties.\(name).format")
            }
            if let maximum = property["maxLength"] {
                try require((1...10_000).contains(try integer(maximum, path: "$.state.schema.properties.\(name).maxLength")), "$.state.schema.properties.\(name).maxLength")
            }
        }
        let required = try (object["required"].map { try array($0, path: "$.state.schema.required") } ?? []).map { try string($0, path: "$.state.schema.required") }
        try require(Set(required).count == required.count && required.allSatisfy { properties[$0] != nil }, "$.state.schema.required")
        return propertyTypes
    }

    private func validateBindings(
        node: PocketSurfaceRenderNode,
        inputTypes: [String: String],
        stateTypes: [String: Set<String>],
        boundNames: inout Set<String>,
        path: String
    ) throws {
        for (key, value) in node.properties {
            if case .string(let binding) = value, binding.hasPrefix("$") {
                if binding.hasPrefix("$input.") {
                    let name = String(binding.dropFirst("$input.".count))
                    guard let declaredType = inputTypes[name],
                          let acceptedTypes = acceptedWorkflowInputTypes(nodeType: node.type, propertyName: key) else {
                        throw PocketAppPackageError.invalid("\(path).\(key):binding")
                    }
                    try require(acceptedTypes.contains(declaredType), "\(path).\(key):binding_type")
                    boundNames.insert(name)
                } else if binding.hasPrefix("$state.") {
                    let name = String(binding.dropFirst("$state.".count))
                    guard let declaredStateTypes = stateTypes[name],
                          let acceptedStateTypes = acceptedStateTypes(nodeType: node.type, propertyName: key) else {
                        throw PocketAppPackageError.invalid("\(path).\(key):binding")
                    }
                    let nonNullStateTypes = declaredStateTypes.subtracting(["null"])
                    try require(
                        !nonNullStateTypes.isEmpty && nonNullStateTypes.isSubset(of: acceptedStateTypes),
                        "\(path).\(key):binding_type"
                    )
                    if let fallbackInputType = inputTypes[name] {
                        guard let acceptedInputTypes = acceptedWorkflowInputTypes(nodeType: node.type, propertyName: key) else {
                            throw PocketAppPackageError.invalid("\(path).\(key):workflow_fallback_type")
                        }
                        try require(
                            acceptedInputTypes.contains(fallbackInputType),
                            "\(path).\(key):workflow_fallback_type"
                        )
                    }
                    boundNames.insert(name)
                } else {
                    throw PocketAppPackageError.invalid("\(path).\(key):binding")
                }
            }
        }
        for (index, child) in node.children.enumerated() {
            try validateBindings(node: child, inputTypes: inputTypes, stateTypes: stateTypes, boundNames: &boundNames, path: "\(path).children[\(index)]")
        }
    }

    private func acceptedWorkflowInputTypes(nodeType: String, propertyName: String) -> Set<String>? {
        switch (nodeType, propertyName) {
        case ("textField", "value"):
            return ["string"]
        case ("toggle", "value"):
            return ["boolean"]
        case ("picker", "value"):
            return ["string"]
        case ("calendarEventPicker", "selection"):
            return ["entity-ref"]
        case ("calendarEventPicker", "titleTarget"):
            return ["string"]
        case ("durationPicker", "value"):
            return ["integer", "number"]
        default:
            return nil
        }
    }

    private func referencedWorkflows(node: PocketSurfaceRenderNode) -> Set<String> {
        var workflows = Set<String>()
        if node.type == "button", case .string(let workflowID) = node.properties["workflow"] {
            workflows.insert(workflowID)
        }
        for child in node.children {
            workflows.formUnion(referencedWorkflows(node: child))
        }
        return workflows
    }

    private func acceptedStateTypes(nodeType: String, propertyName: String) -> Set<String>? {
        switch (nodeType, propertyName) {
        case ("textField", "value"):
            return ["string"]
        case ("toggle", "value"):
            return ["boolean"]
        case ("picker", "value"):
            return ["string"]
        case ("calendarEventPicker", "selection"), ("calendarEventPicker", "titleTarget"):
            return ["string"]
        case ("durationPicker", "value"):
            return ["integer", "number"]
        default:
            return nil
        }
    }

    private func validateWorkflowBinding(_ value: PocketJSONValue, inputs: Set<String>, path: String) throws {
        switch value {
        case .string(let text) where text.hasPrefix("$"):
            let inputBinding = text.hasPrefix("$input.") && inputs.contains(String(text.dropFirst("$input.".count)))
            let contextBinding = text == "$context.todayFocusStableKey"
            try require(inputBinding || contextBinding, "\(path):binding")
        case .array(let values):
            for (index, value) in values.enumerated() { try validateWorkflowBinding(value, inputs: inputs, path: "\(path)[\(index)]") }
        case .object(let object):
            for (key, value) in object { try validateWorkflowBinding(value, inputs: inputs, path: "\(path).\(key)") }
        default:
            break
        }
    }

    private func validateSurfaceScopes(
        node: PocketSurfaceRenderNode,
        requestedScopes: [PocketCapabilityKey: PocketJSONValue?],
        path: String
    ) throws {
        if node.type == "calendarEventPicker",
           case .object(let items)? = node.properties["items"],
           case .string(let query)? = items["query"],
           case .object(let arguments)? = items["arguments"] {
            let key = try capabilityKey(query, path: "\(path).items.query")
            try require(key == PocketCapabilityKeys.calendarList, "\(path).items.query:unsupported_shape")
            try require(requestedScopes.keys.contains(key), "\(path).items.query:undeclared")
            try validateCapabilityScope(
                arguments: arguments,
                scope: requestedScopes[key] ?? nil,
                key: key,
                path: "\(path).items.arguments"
            )
        }
        for (index, child) in node.children.enumerated() {
            try validateSurfaceScopes(node: child, requestedScopes: requestedScopes, path: "\(path).children[\(index)]")
        }
    }

    private func validateCapabilityScope(
        arguments: [String: PocketJSONValue],
        scope: PocketJSONValue?,
        key: PocketCapabilityKey,
        path: String
    ) throws {
        guard case .object(let object)? = scope else { return }
        if case .string(let range)? = object["range"] {
            try require(arguments["range"] == .string(range), "\(path).range:scope")
        }
        if case .string(let namespace)? = object["namespace"] {
            guard case .string(let stableKey)? = arguments["stableKey"] else {
                throw PocketAppPackageError.invalid("\(path).stableKey:scope")
            }
            let contextBinding = namespace == "today-focus" && stableKey == "$context.todayFocusStableKey"
            let literalBinding = !stableKey.hasPrefix("$")
                && (try? PocketStableKey.namespace(stableKey)) == namespace
            try require(literalBinding || contextBinding, "\(path).stableKey:scope")
        }
        _ = key
    }

    private func validateScope(_ scope: PocketJSONValue?, key: PocketCapabilityKey, path: String) throws {
        switch (key.id, scope) {
        case ("calendar.events.list", .some(.object(let object))):
            try require(Set(object.keys) == ["range"] && object["range"] == .string("today"), path)
        case ("sticky.note.get", .some(.object(let object))), ("sticky.note.upsert", .some(.object(let object))):
            try require(Set(object.keys) == ["namespace"] && object["namespace"] == .string("today-focus"), path)
        case (_, nil):
            break
        default:
            throw PocketAppPackageError.invalid(path)
        }
    }

    private func inventory(root: URL) throws -> [String: Int] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys), options: []) else {
            throw PocketAppPackageError.invalid("$:package_inventory")
        }
        var files: [String: Int] = [:]
        var total = 0
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: keys)
            try require(values.isSymbolicLink != true, "$:package_symlink")
            if values.isDirectory == true { continue }
            try require(values.isRegularFile == true, "$:package_file")
            let relative = String(url.standardizedFileURL.path.dropFirst(root.path.count + 1))
            try require(isSafeRelativePath(relative), "$:package_path")
            let size = values.fileSize ?? 0
            try require(size <= Self.maximumFileBytes, "$:package_file_size")
            try require(files[relative] == nil, "$:package_duplicate")
            files[relative] = size
            total += size
            try require(files.count <= Self.maximumFiles && total <= Self.maximumPackageBytes, "$:package_size")
        }
        return files
    }

    private func read(relativePath: String, root: URL, inventory: [String: Int]) throws -> Data {
        try require(inventory[relativePath] != nil && isSafeRelativePath(relativePath), "$:package_reference")
        let url = root.appendingPathComponent(relativePath, isDirectory: false).standardizedFileURL
        try require(url.path.hasPrefix(root.path + "/"), "$:package_reference")
        return try Data(contentsOf: url, options: [.mappedIfSafe])
    }

    private func jsonObject(_ data: Data, path: String) throws -> [String: Any] {
        try require(data.count <= Self.maximumFileBytes, "\(path):size")
        do {
            return try dictionary(JSONSerialization.jsonObject(with: data, options: []), path: path)
        } catch let error as PocketAppPackageError {
            throw error
        } catch {
            throw PocketAppPackageError.invalid("\(path):json")
        }
    }

    private func packageData(_ path: String, files: [String: Data]) throws -> Data {
        guard let data = files[path] else { throw PocketAppPackageError.invalid("$:package_reference") }
        return data
    }

    private func packageDigest(_ files: [String: Data]) -> String {
        var hasher = SHA256()
        hasher.update(data: Data("hoverpocket.package/v1\0".utf8))
        for path in files.keys.sorted() {
            hasher.update(data: Data(path.utf8))
            hasher.update(data: Data([0]))
            hasher.update(data: Data(SHA256.hash(data: files[path]!)))
        }
        return "sha256:" + hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func capabilityKey(_ value: String, path: String) throws -> PocketCapabilityKey {
        guard let marker = value.lastIndex(of: "@"),
              let version = Int(value[value.index(after: marker)...]),
              version >= 1 else { throw PocketAppPackageError.invalid(path) }
        let id = String(value[..<marker])
        try require(matches(id, "^[a-z][a-z0-9]*(?:\\.[a-z][a-z0-9_]*){2,}$"), path)
        return PocketCapabilityKey(id: id, version: version)
    }

    private func safePath(_ value: Any?, path: String) throws -> String {
        let result = try boundedString(value, range: 1...240, path: path)
        try require(isSafeRelativePath(result), path)
        return result
    }

    private func isSafeRelativePath(_ value: String) -> Bool {
        guard !value.isEmpty, !value.hasPrefix("/"), !value.contains("\\"), !value.contains("\0") else { return false }
        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        return components.allSatisfy { component in
            !component.isEmpty && component != "." && component != ".." && component.unicodeScalars.allSatisfy {
                CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-")).contains($0)
            }
        }
    }

    private func semanticVersion(_ value: Any?, path: String) throws -> String {
        let result = try boundedString(value, range: 1...64, path: path)
        try require(matches(result, "^(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)(?:-[0-9A-Za-z.-]+)?$"), path)
        return result
    }

    private func identifier(_ value: Any?, path: String) throws -> String {
        let result = try boundedString(value, range: 1...64, path: path)
        try require(matches(result, "^[A-Za-z][A-Za-z0-9_-]{0,63}$"), path)
        return result
    }

    private func identifier(_ value: String, path: String) throws -> String {
        try require(matches(value, "^[A-Za-z][A-Za-z0-9_-]{0,63}$"), path)
        return value
    }

    private func exactKeys(_ object: [String: Any], required: Set<String>, optional: Set<String>, path: String) throws {
        let keys = Set(object.keys)
        try require(required.isSubset(of: keys) && keys.isSubset(of: required.union(optional)), "\(path):keys")
    }

    private func dictionary(_ value: Any?, path: String) throws -> [String: Any] {
        guard let value = value as? [String: Any], value.count <= 128 else { throw PocketAppPackageError.invalid("\(path):object") }
        return value
    }

    private func array(_ value: Any?, path: String) throws -> [Any] {
        guard let value = value as? [Any], value.count <= 256 else { throw PocketAppPackageError.invalid("\(path):array") }
        return value
    }

    private func string(_ value: Any?, path: String) throws -> String {
        guard let value = value as? String else { throw PocketAppPackageError.invalid("\(path):string") }
        return value
    }

    private func boundedString(_ value: Any?, range: ClosedRange<Int>, path: String) throws -> String {
        let value = try string(value, path: path)
        try require(range.contains(value.unicodeScalars.count), path)
        return value
    }

    private func integer(_ value: Any?, path: String) throws -> Int {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite,
              number.doubleValue.rounded() == number.doubleValue,
              number.doubleValue >= Double(Int.min), number.doubleValue <= Double(Int.max) else {
            throw PocketAppPackageError.invalid("\(path):integer")
        }
        return number.intValue
    }

    private func boolean(_ value: Any?, path: String) throws -> Bool {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
            throw PocketAppPackageError.invalid("\(path):boolean")
        }
        return number.boolValue
    }

    private func matches(_ value: String, _ pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
    }

    private func require(_ condition: @autoclosure () throws -> Bool, _ path: String) throws {
        if try !condition() { throw PocketAppPackageError.invalid(path) }
    }
}
