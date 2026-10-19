import AppKit
import WhubAgent

/// Keeps AppKit images and local command display out of the execution model.
@MainActor
final class AgentModelMapping {
    private var images: [UUID: AgentImageAttachment] = [:]

    func input(_ input: [AgentInput]) throws -> [WhubAgent.AgentInput] {
        try input.map { item in
            switch item {
            case .text(let text): return .text(text)
            case .skill(let skill): return .skill(skill)
            case .image(let attachment):
                guard let tiff = attachment.image.tiffRepresentation,
                      let bitmap = NSBitmapImageRep(data: tiff),
                      let png = bitmap.representation(using: .png, properties: [:]) else {
                    throw AgentError(.invalidInput, "画像を送信用のPNGへ変換できませんでした。")
                }
                images[attachment.id] = attachment
                return .image(try .init(id: attachment.id, data: png, mediaType: "image/png"))
            case .slashCommand:
                throw AgentError(.invalidInput, "コマンドは会話入力と分けて実行してください。")
            }
        }
    }

    func exchanges(_ exchanges: [WhubAgent.AgentExchange]) throws -> [AgentExchange] {
        try exchanges.map { source in
            var exchange = AgentExchange(id: source.id, input: try source.input.map(input))
            exchange.additionalInputs = try source.additionalInputs.map {
                AgentAdditionalInput(id: $0.id, input: try $0.input.map(input), outputIndex: $0.outputIndex)
            }
            exchange.outputs = try source.outputs.map { output in
                switch output {
                case .message(let message):
                    return .message(.init(id: message.id, role: message.role, title: message.title,
                                          content: try content(message.content), status: message.status))
                case .toolUse(let tool):
                    return .toolUse(.init(id: tool.id, tool: tool.tool, arguments: try tool.arguments.map(content),
                                          result: try tool.result?.map(content), status: tool.status))
                case .request(let request): return .request(request)
                }
            }
            exchange.status = source.status
            return exchange
        }
    }

    func content(_ content: WhubAgent.AgentContent) throws -> AgentContent {
        switch content {
        case .text(let text): .text(text)
        case .markdown(let text): .markdown(text)
        case .code(let text): .code(text)
        case .image(let attachment): .image(try image(attachment))
        }
    }

    private func input(_ input: WhubAgent.AgentInput) throws -> AgentInput {
        switch input {
        case .text(let text): .text(text)
        case .skill(let skill): .skill(skill)
        case .image(let attachment): .image(try image(attachment))
        }
    }

    private func image(_ attachment: WhubAgent.AgentImageAttachment) throws -> AgentImageAttachment {
        if let image = images[attachment.id] { return image }
        guard let image = NSImage(data: attachment.data) else {
            throw AgentError(.invalidInput, "画像データを表示できませんでした。")
        }
        let result = AgentImageAttachment(id: attachment.id, image: image)
        images[attachment.id] = result
        return result
    }
}
