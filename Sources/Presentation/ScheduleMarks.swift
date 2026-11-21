import Foundation

// 番組表の予約済みの印。AppKit・SwiftUI に依存させない（iPad 版でも同じ照らし方にする）

/// 予約の一覧から、番組表の番組が予約済みかを照らす。
///
/// - 番組に紐付けた予約（eventId あり）：帯域・serviceID・eventId が同じ番組
/// - 手動の予約（eventId 0）：同じ帯域・serviceID で、時間が重なる番組（端が接しているだけは重ならない）
///
/// 手動の予約は終わった後も一覧に残るので、録り終えた時間の番組にも印が付く
public struct ScheduleMarks: Sendable, Equatable {
    private struct ServiceKey: Hashable, Sendable {
        let broadcastingType: Int
        let serviceID: Int
    }

    private struct EventKey: Hashable, Sendable {
        let service: ServiceKey
        let eventID: Int
    }

    private struct Span: Equatable, Sendable {
        let start: Date
        let end: Date
    }

    private let linked: Set<EventKey>
    private let manual: [ServiceKey: [Span]]

    /// 印を付けない（予約の一覧をまだ読んでいない・読めなかった）
    public static let none = ScheduleMarks([])

    public init(_ schedules: [RecordSchedule]) {
        var linked: Set<EventKey> = []
        var manual: [ServiceKey: [Span]] = [:]
        for schedule in schedules {
            let service = ServiceKey(broadcastingType: schedule.channel.broadcastingType, serviceID: schedule.channel.serviceID)
            if let eventID = schedule.eventID, eventID != 0 {
                linked.insert(EventKey(service: service, eventID: eventID))
            } else {
                manual[service, default: []].append(Span(start: schedule.start, end: schedule.end))
            }
        }
        self.linked = linked
        self.manual = manual
    }

    /// 印が 1 つも無いか
    public var isEmpty: Bool { linked.isEmpty && manual.isEmpty }

    /// 局 `channel` の番組 `event` が予約済みか
    public func isReserved(_ event: BroadcastEvent, on channel: Channel) -> Bool {
        let service = ServiceKey(broadcastingType: channel.broadcastingType, serviceID: channel.serviceID)
        if linked.contains(EventKey(service: service, eventID: Int(event.eventID))) { return true }
        guard let spans = manual[service], let start = event.start else { return false }
        let end = event.end ?? start
        return spans.contains { $0.start < end && start < $0.end }
    }
}
