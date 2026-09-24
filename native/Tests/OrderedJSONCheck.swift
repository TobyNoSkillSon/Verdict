import Foundation

// Standalone structural check of the helper's renderer; builds without MLX.
struct ServiceError: Error { let description: String; init(_ description: String) { self.description = description } }

@main enum OrderedJSONCheck {
    static func main() throws {
        while let line = readLine() {
            var parser = OrderedJSONParser(Data(line.utf8))
            guard let value = try parser.parse()["item"] else { throw ServiceError("missing item") }
            print(value.render())
        }
    }
}
