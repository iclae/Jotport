import Foundation

public struct SessionInbox {
    private enum Disposition {
        case keep
        case discard
        case save(Block, at: Int)
    }

    private let directory: URL
    private let store: Store

    public init(directory: URL, store: Store) {
        self.directory = directory
        self.store = store
    }

    public func consume(into blocks: inout [Block]) -> Error? {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        let events = files.compactMap { file -> (file: URL, event: BridgeEvent)? in
            guard file.pathExtension == "json", let data = try? Data(contentsOf: file), data.count < 100_000,
                  let event = try? decoder.decode(BridgeEvent.self, from: data),
                  event.schemaVersion == 1, !event.sessionID.isEmpty else { return nil }
            return (file, event)
        }.sorted { $0.event.sequence < $1.event.sequence }

        var firstError: Error?
        var failedRuns: Set<String> = []
        for (file, event) in events {
            guard !failedRuns.contains(event.runID) else { continue }
            switch disposition(for: event, in: blocks) {
            case .keep:
                continue
            case .discard:
                break
            case let .save(block, index):
                do {
                    try store.save(block)
                    blocks[index] = block
                } catch {
                    if firstError == nil { firstError = error }
                    failedRuns.insert(event.runID)
                    continue
                }
            }
            try? FileManager.default.removeItem(at: file)
        }
        return firstError
    }

    private func disposition(for event: BridgeEvent, in blocks: [Block]) -> Disposition {
        if let index = blocks.firstIndex(where: { $0.run?.id == event.runID }), let run = blocks[index].run {
            guard let updated = apply(event, to: blocks[index], run: run) else { return .discard }
            return .save(updated, at: index)
        }

        for (index, block) in blocks.enumerated() {
            guard let association = block.history.firstIndex(where: { $0.detachedRunID == event.runID }) else { continue }
            guard block.history[association].agent == event.source, block.history[association].sessionID == nil else {
                return .discard
            }
            var updated = block
            updated.history[association].sessionID = event.sessionID
            return .save(updated, at: index)
        }
        return .keep
    }

    private func apply(_ event: BridgeEvent, to block: Block, run: Run) -> Block? {
        guard event.sequence > run.lastSequence, event.turnID >= run.turn,
              !block.seenEvents.contains(event.eventID), event.source == block.association?.agent else { return nil }
        var updated = block
        var run = run
        updated.seenEvents.insert(event.eventID)
        if let sessionID = block.association?.sessionID, sessionID != event.sessionID {
            run.status = "状态未知：终端会话已切换"
            updated.run = run
            return updated
        }

        updated.association?.sessionID = event.sessionID
        run.lastSequence = event.sequence
        run.turn = event.turnID
        switch event.type {
        case "bound":
            run.status = "已打开，待粘贴"
        case "prefilled":
            run.status = "待发送"
            run.injected = true
        case "running":
            run.status = "运行中"
        case "idle":
            run.status = "空闲"
        case "waiting":
            run.status = "需要输入"
            updated.attention = event.eventID
            updated.attentionTime = event.time
        case "settled" where event.turnID > 0:
            run.status = "结果待查看"
            updated.attention = event.eventID
            updated.attentionTime = event.time
            if let text = event.text, !text.isEmpty {
                updated.recap = String(text.prefix(4000))
                updated.recapSource = "\(event.sessionID) · 轮次 \(event.turnID) · \(event.time)"
            }
        case "settled":
            break
        case "exited":
            run.status = "已退出"
        default:
            run.status = "状态未知"
        }
        updated.run = run
        return updated
    }
}
