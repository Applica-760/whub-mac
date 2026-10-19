import Foundation

public enum AgentInput: Codable, Sendable, Equatable {
    case text(String)
    case skill(AgentSkill)
    case image(AgentImageAttachment)
}

public struct AgentImageAttachment: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public let data: Data
    public let mediaType: String

    public init(id: UUID = UUID(), data: Data, mediaType: String) throws {
        guard !data.isEmpty, ["image/png", "image/jpeg", "image/gif", "image/webp"].contains(mediaType) else {
            throw AgentError(.invalidInput, "画像データと対応する画像形式を指定してください。")
        }
        self.id = id
        self.data = data
        self.mediaType = mediaType
    }

    private enum CodingKeys: String, CodingKey { case id, data, mediaType, byteCount }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(mediaType, forKey: .mediaType)
        if encoder.userInfo[.agentImageReferences] as? Bool == true {
            try values.encode(data.count, forKey: .byteCount)
        } else {
            try values.encode(data, forKey: .data)
        }
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let id = try values.decode(UUID.self, forKey: .id)
        let data: Data
        if values.contains(.data) {
            data = try values.decode(Data.self, forKey: .data)
        } else {
            guard let cached = (decoder.userInfo[.agentImageData] as? [UUID: Data])?[id],
                  cached.count == (try values.decode(Int.self, forKey: .byteCount)) else {
                throw DecodingError.dataCorruptedError(forKey: .data, in: values, debugDescription: "Image reference has no matching data.")
            }
            data = cached
        }
        try self.init(id: id, data: data, mediaType: values.decode(String.self, forKey: .mediaType))
    }
}
