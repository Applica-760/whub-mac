import Foundation
import WhubCore

@MainActor
func run() throws {
    let arguments = Array(CommandLine.arguments.dropFirst())
    if arguments.count == 2, arguments[0] == "host" {
        try HostCommand.run(name: arguments[1])
        return
    }
    guard arguments == ["projects", "--json"] else {
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
    FileHandle.standardError.write(Data("usage: whub-mac projects --json\n       whub-mac host <Host.name>\n".utf8))
    exit(2)
} catch {
    FileHandle.standardError.write(Data("whub-mac: \(error.localizedDescription)\n".utf8))
    exit(1)
}
