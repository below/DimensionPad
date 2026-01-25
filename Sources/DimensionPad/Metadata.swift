import Foundation

public struct CharacterMetadata: Codable, Sendable {
    public let id: Int
    public let name: String
    public let world: String
}

public struct VehicleMetadata: Codable, Sendable {
    public let id: Int
    public let name: String
    public let world: String
    public let parentId: Int?
    public let step: Int?
}

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

    public static func getCharacterById(_ id: Int) -> CharacterMetadata? {
        characters[id]
    }

    public static func getVehicleById(_ id: Int) -> VehicleMetadata? {
        vehicles[id]
    }

    public static func listCharacters() -> [CharacterMetadata] {
        characterList
    }

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
