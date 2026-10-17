import Foundation

nonisolated enum FileEncoding {
    static func decode(_ data: Data) -> String? {
        String(data: data, encoding: .utf8)
    }

    static func encode(_ source: String, preserving original: Data) -> Data {
        Data(encode(source, preserving: String(decoding: original, as: UTF8.self)).utf8)
    }

    static func encode(_ source: String, preserving original: String) -> String {
        var output = source
        let withoutCRLF = original.replacingOccurrences(of: "\r\n", with: "")
        let lineEnding: String? = if original.contains("\r\n") && !withoutCRLF.contains("\r") && !withoutCRLF.contains("\n") {
            "\r\n"
        } else if !original.contains("\n") && original.contains("\r") {
            "\r"
        } else if !original.contains("\r") {
            "\n"
        } else { nil }
        if let lineEnding {
            output = output.replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n").replacingOccurrences(of: "\n", with: lineEnding)
        }
        if original.hasPrefix("\u{FEFF}"), !output.hasPrefix("\u{FEFF}") { output = "\u{FEFF}" + output }
        return output
    }
}
