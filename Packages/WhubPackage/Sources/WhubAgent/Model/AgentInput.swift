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

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: values.decode(UUID.self, forKey: .id),
                      data: values.decode(Data.self, forKey: .data),
                      mediaType: values.decode(String.self, forKey: .mediaType))
    }
}
