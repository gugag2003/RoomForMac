import Foundation

enum EngineJSON {
    /// The engine writes snake_case keys; models use the converted camelCase names.
    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }
}
