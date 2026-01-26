import Foundation

/// Character metadata decoded from the bundled dataset.
public struct CharacterMetadata: Codable, Sendable {
    public let id: Int
    public let name: String
    public let world: String
}

/// Vehicle metadata decoded from the bundled dataset.
public struct VehicleMetadata: Codable, Sendable {
    public let id: Int
    public let name: String
    public let world: String
    public let parentId: Int?
    public let step: Int?
}

/// Lookup helper for bundled character and vehicle metadata.
public enum DimensionPadMetadata {
    private static let characterList: [CharacterMetadata] = {
        loadArray("minifigs", as: CharacterMetadata.self)
    }()

    private static let vehicleList: [VehicleMetadata] = {
        loadArray("vehicles", as: VehicleMetadata.self)
    }()

    private static let characters: [Int: CharacterMetadata] = {
        characterList.reduce(into: [:]) { $0[$1.id] = $1 }
    }()

    private static let vehicles: [Int: VehicleMetadata] = {
        vehicleList.reduce(into: [:]) { $0[$1.id] = $1 }
    }()

    /// Fetch a character by ID.
    public static func getCharacterById(_ id: Int) -> CharacterMetadata? {
        characters[id]
    }

    /// Fetch a vehicle by ID.
    public static func getVehicleById(_ id: Int) -> VehicleMetadata? {
        vehicles[id]
    }

    /// List all characters in the bundled dataset.
    public static func listCharacters() -> [CharacterMetadata] {
        characterList
    }

    /// List all vehicles in the bundled dataset.
    public static func listVehicles() -> [VehicleMetadata] {
        vehicleList
    }

    private static func loadArray<T: Decodable>(_ name: String, as type: T.Type) -> [T] {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json") else {
            return []
        }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode([T].self, from: data)
        } catch {
            return []
        }
    }
}
