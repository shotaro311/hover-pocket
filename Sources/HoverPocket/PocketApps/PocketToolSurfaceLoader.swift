import Foundation

enum PocketToolSurfaceLoader {
    static func load(id: String, kind: String, data: Data,
                     collections: [String: PocketCollectionSchema]) throws -> PocketSurfaceDocument {
        let properties: [String: PocketJSONValue]
        switch kind {
        case "collection":
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  Set(object.keys) == ["$schema", "id", "collection", "titleField"],
                  object["$schema"] as? String == "hoverpocket://schemas/pocket-collection-surface/v1",
                  object["id"] as? String == id,
                  let collection = object["collection"] as? String, let schema = collections[collection],
                  let titleField = object["titleField"] as? String,
                  schema.fields[titleField]?.type == "string" else {
                throw PocketAppPackageError.invalid("$.surfaces.\(id):collection")
            }
            properties = ["collection": .string(collection), "titleField": .string(titleField)]
        case "html":
            guard data.count <= 256 * 1_024, let html = String(data: data, encoding: .utf8),
                  !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !html.contains("\0") else {
                throw PocketAppPackageError.invalid("$.surfaces.\(id):html")
            }
            properties = ["html": .string(html)]
        default: throw PocketAppPackageError.invalid("$.surfaces.\(id):kind")
        }
        return PocketSurfaceDocument(id: id,
            root: PocketSurfaceRenderNode(type: kind, properties: properties, children: []),
            nodeCount: 1, maximumDepth: 1)
    }
}
