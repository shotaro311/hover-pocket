import CryptoKit
import Foundation

enum PocketSurfaceVerificationCommand {
    private static let goldenRenderDigest = "sha256:6e3ac77b36cc0aeb3f93e1cf6350b0ef134bc2757f7888ee3687e0aa1058dba1"

    static func run() -> Never {
        var failures: [String] = []
        var renderDigest = "unavailable"
        let runtime = PocketSurfaceRuntime(
            knownQueries: ["calendar.events.list@1", "sticky.note.get@1"],
            knownWorkflows: ["startFocus"]
        )

        do {
            let valid = try fixtureData("valid/pocket-surface.today-focus.json")
            let document = try runtime.load(data: valid)
            require(document.id == "main", "surface_id", failures: &failures)
            require(document.nodeCount == 6, "node_count", failures: &failures)
            require(document.maximumDepth == 2, "maximum_depth", failures: &failures)

            let rendered = try document.canonicalRenderModelData()
            renderDigest = "sha256:" + SHA256.hash(data: rendered)
                .map { String(format: "%02x", $0) }
                .joined()
            let renderedAgain = try runtime.load(data: valid).canonicalRenderModelData()
            require(rendered == renderedAgain, "render_determinism", failures: &failures)
            require(renderDigest == goldenRenderDigest, "render_golden_digest", failures: &failures)
            require(
                String(data: rendered, encoding: .utf8)?.contains("calendar.events.list@1") == true,
                "render_query",
                failures: &failures
            )
            require(
                document.root.children[1].stringProperty("titleTarget") == "$input.purpose",
                "selection_title_target",
                failures: &failures
            )
            require(
                document.root.children[2].integerProperty("default") == 1_500,
                "duration_default",
                failures: &failures
            )
        } catch {
            failures.append("valid_fixture:\(error)")
        }
        verifyOmittedDurationDefault(runtime: runtime, failures: &failures)

        rejectFixture("invalid/pocket-surface.asset-traversal.json", runtime: runtime, failures: &failures)
        rejectFixture("invalid/pocket-surface.receipt-component.json", runtime: runtime, failures: &failures)
        rejectMutation(
            ["root": ["children": [0, ["unexpected": true]]]],
            label: "unknown_key",
            runtime: runtime,
            failures: &failures
        )
        rejectMutation(
            ["root": ["children": [0, ["type": "webView"]]]],
            label: "unknown_component",
            runtime: runtime,
            failures: &failures
        )
        rejectMutation(
            ["root": ["children": [1, ["items": ["query": "calendar.events.delete@1"]]]]],
            label: "unknown_query",
            runtime: runtime,
            failures: &failures
        )
        rejectMutation(
            ["root": ["children": [1, ["items": ["query": "sticky.note.get@1"]]]]],
            label: "unsupported_query_shape",
            runtime: runtime,
            failures: &failures
        )
        rejectMutation(
            ["root": ["children": [4, ["workflow": "missing"]]]],
            label: "unknown_workflow",
            runtime: runtime,
            failures: &failures
        )
        rejectMutation(
            ["root": ["children": [2, ["min": 500, "max": 60]]]],
            label: "duration_range",
            runtime: runtime,
            failures: &failures
        )
        rejectMutation(
            ["root": ["children": [2, ["default": 14_401]]]],
            label: "duration_default",
            runtime: runtime,
            failures: &failures
        )
        rejectMutation(
            ["root": ["children": [1, ["titleTarget": "$state.purpose"]]]],
            label: "selection_title_target",
            runtime: runtime,
            failures: &failures
        )
        rejectData(Data(repeating: 0x20, count: PocketSurfaceRuntime.maximumDocumentBytes + 1), label: "document_size", runtime: runtime, failures: &failures)
        rejectSynthetic(root: deepRoot(), label: "depth", runtime: runtime, failures: &failures)
        rejectSynthetic(root: wideRoot(), label: "node_count", runtime: runtime, failures: &failures)
        rejectMutation(
            ["root": ["children": [4, ["label": String(repeating: "界", count: 121)]]]],
            label: "unicode_scalar_limit",
            runtime: runtime,
            failures: &failures
        )
        rejectSynthetic(
            root: ["type": "status", "value": "保存済み", "tone": "success"],
            label: "host_receipt_spoof",
            runtime: runtime,
            failures: &failures
        )

        print("pocket_surface_verify=\(failures.isEmpty ? "ok" : "failed")")
        print("pocket_surface_valid_nodes=6")
        print("pocket_surface_negative_cases=15")
        print("pocket_surface_render_digest=\(renderDigest)")
        if !failures.isEmpty {
            print("pocket_surface_failures=\(failures.joined(separator: ","))")
        }
        exit(failures.isEmpty ? 0 : 1)
    }

    private static func rejectFixture(
        _ relativePath: String,
        runtime: PocketSurfaceRuntime,
        failures: inout [String]
    ) {
        do {
            let data = try fixtureData(relativePath)
            _ = try runtime.load(data: data)
            failures.append("accepted:\(relativePath)")
        } catch {
        }
    }

    private static func verifyOmittedDurationDefault(
        runtime: PocketSurfaceRuntime,
        failures: inout [String]
    ) {
        do {
            let base = try JSONSerialization.jsonObject(with: fixtureData("valid/pocket-surface.today-focus.json"))
            guard var object = base as? [String: Any],
                  var root = object["root"] as? [String: Any],
                  var children = root["children"] as? [[String: Any]] else {
                failures.append("duration_default_omitted:base")
                return
            }
            children[2].removeValue(forKey: "default")
            root["children"] = children
            object["root"] = root
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            let document = try runtime.load(data: data)
            require(
                document.root.children[2].integerProperty("default") == 60,
                "duration_default_omitted",
                failures: &failures
            )
        } catch {
            failures.append("duration_default_omitted:\(error)")
        }
    }

    private static func rejectMutation(
        _ mutation: [String: Any],
        label: String,
        runtime: PocketSurfaceRuntime,
        failures: inout [String]
    ) {
        do {
            let base = try JSONSerialization.jsonObject(with: fixtureData("valid/pocket-surface.today-focus.json"))
            guard var object = base as? [String: Any] else {
                failures.append("\(label):base")
                return
            }
            apply(mutation, to: &object)
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            _ = try runtime.load(data: data)
            failures.append("accepted:\(label)")
        } catch {
        }
    }

    private static func apply(_ mutation: [String: Any], to target: inout [String: Any]) {
        for (key, value) in mutation {
            if let nested = value as? [String: Any], var current = target[key] as? [String: Any] {
                apply(nested, to: &current)
                target[key] = current
            } else if let path = value as? [Any],
                      path.count == 2,
                      let index = path[0] as? Int,
                      let nested = path[1] as? [String: Any],
                      var array = target[key] as? [[String: Any]],
                      array.indices.contains(index) {
                var current = array[index]
                apply(nested, to: &current)
                array[index] = current
                target[key] = array
            } else {
                target[key] = value
            }
        }
    }

    private static func rejectData(
        _ data: Data,
        label: String,
        runtime: PocketSurfaceRuntime,
        failures: inout [String]
    ) {
        do {
            _ = try runtime.load(data: data)
            failures.append("accepted:\(label)")
        } catch {
        }
    }

    private static func rejectSynthetic(
        root: [String: Any],
        label: String,
        runtime: PocketSurfaceRuntime,
        failures: inout [String]
    ) {
        do {
            let document: [String: Any] = [
                "$schema": "hoverpocket://schemas/pocket-surface/v1",
                "surfaceVersion": 1,
                "id": "verification",
                "hostBoundary": [
                    "region": "provider_host",
                    "mayRenderHeader": false,
                    "mayRenderVoiceLane": false,
                    "mayRenderApproval": false,
                    "mayRenderReceipt": false
                ],
                "root": root
            ]
            let data = try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
            rejectData(data, label: label, runtime: runtime, failures: &failures)
        } catch {
            failures.append("\(label):fixture:\(error)")
        }
    }

    private static func deepRoot() -> [String: Any] {
        var root: [String: Any] = [
            "type": "status",
            "value": "deep",
            "tone": "neutral"
        ]
        for _ in 0..<PocketSurfaceRuntime.maximumDepth {
            root = [
                "type": "stack",
                "axis": "vertical",
                "children": [root]
            ]
        }
        return root
    }

    private static func wideRoot() -> [String: Any] {
        let groups: [[String: Any]] = (0..<4).map { groupIndex in
            let children: [[String: Any]] = (0..<64).map { childIndex in
                [
                    "type": "text",
                    "style": "caption",
                    "value": "\(groupIndex):\(childIndex)"
                ]
            }
            return [
                "type": "stack",
                "axis": "vertical",
                "children": children
            ]
        }
        return [
            "type": "stack",
            "axis": "vertical",
            "children": groups
        ]
    }

    private static func fixtureData(_ relativePath: String) throws -> Data {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let url = root
            .appendingPathComponent("contracts/pocket/v1/fixtures", isDirectory: true)
            .appendingPathComponent(relativePath, isDirectory: false)
        return try Data(contentsOf: url)
    }

    private static func require(_ condition: Bool, _ label: String, failures: inout [String]) {
        if !condition {
            failures.append(label)
        }
    }
}
