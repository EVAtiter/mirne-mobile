import Foundation

// 番組表の予約済みの印。AppKit・SwiftUI に依存させない（iPad 版でも同じ照らし方にする）

/// 予約の一覧から、番組表の番組が予約済みかを照らす。
///
/// - 番組に紐付けた予約（eventId あり）：帯域・serviceID・eventId が同じ番組
/// - 手動の予約（eventId 0）：同じ帯域・serviceID で、時間が重なる番組（端が接しているだけは重ならない）。
///   番組の始まりから終わりまでを含むときは番組に紐付けた予約と同じ印、一部だけ重なるときは別の印（2026-11-24。
///   前は一部だけでも同じ印で、5 分の予約で 50 分の番組全体が予約済みに見えた）
///
/// 手動の予約は終わった後も一覧に残るので、録り終えた時間の番組にも印が付く
/// 予約済みの印の種類
public enum ScheduleMark: Sendable, Equatable {
    /// 番組の全体を録る（番組に紐付けた予約・番組を含む手動の予約）
    case whole
    /// 番組の一部だけを録る（一部だけ重なる手動の予約）
    case part
}

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

    /// 局 `channel` の番組 `event` の予約済みの印（予約していなければ nil）
    public func mark(_ event: BroadcastEvent, on channel: Channel) -> ScheduleMark? {
        let service = ServiceKey(broadcastingType: channel.broadcastingType, serviceID: channel.serviceID)
        if linked.contains(EventKey(service: service, eventID: Int(event.eventID))) { return .whole }
        guard let spans = manual[service], let start = event.start else { return nil }
        let end = event.end ?? start
        let overlapping = spans.filter { $0.start < end && start < $0.end }
        guard !overlapping.isEmpty else { return nil }
        return overlapping.contains { $0.start <= start && end <= $0.end } ? .whole : .part
    }
}
