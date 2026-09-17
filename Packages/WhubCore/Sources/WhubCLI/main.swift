import Foundation
import WhubCore

@MainActor
func run() throws {
    guard CommandLine.arguments.dropFirst().elementsEqual(["projects", "--json"]) else {
        throw CLIError.usage
    }

    let container = try Container.make()
    let store = ProjectStore(context: container.mainContext)
    let names = try store.fetchProjects().map(\.name)
    let data = try JSONEncoder().encode(names)
    print(String(decoding: data, as: UTF8.self))
}

enum CLIError: Error {
    case usage
}

do {
    try run()
} catch CLIError.usage {
    FileHandle.standardError.write(Data("usage: whub projects --json\n".utf8))
    exit(2)
} catch {
    FileHandle.standardError.write(Data("whub: \(error.localizedDescription)\n".utf8))
    exit(1)
}
