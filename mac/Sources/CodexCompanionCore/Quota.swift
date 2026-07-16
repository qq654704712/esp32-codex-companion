import Foundation

public struct RateLimitWindow: Equatable, Sendable {
    public let windowDurationMins: Int
    public let usedPercent: Double
    public let resetsAt: Int64?

    public init(windowDurationMins: Int, usedPercent: Double, resetsAt: Int64?) {
        self.windowDurationMins = windowDurationMins
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
    }
}

public struct QuotaSnapshot: Codable, Equatable, Sendable {
    public let fiveHourRemainingPercent: Double?
    public let weekRemainingPercent: Double?
    public let fiveHourResetsAt: Int64?
    public let weekResetsAt: Int64?
    public let updatedAt: Int64

    public init(
        fiveHourRemainingPercent: Double?,
        weekRemainingPercent: Double?,
        fiveHourResetsAt: Int64?,
        weekResetsAt: Int64?,
        updatedAt: Int64
    ) {
        self.fiveHourRemainingPercent = fiveHourRemainingPercent
        self.weekRemainingPercent = weekRemainingPercent
        self.fiveHourResetsAt = fiveHourResetsAt
        self.weekResetsAt = weekResetsAt
        self.updatedAt = updatedAt
    }
}

public enum QuotaMapper {
    public static func map(windows: [RateLimitWindow], updatedAt: Int64) -> QuotaSnapshot {
        let fiveHour = windows.first(where: { $0.windowDurationMins == 300 })
        let week = windows.first(where: { $0.windowDurationMins == 10_080 })
        return QuotaSnapshot(
            fiveHourRemainingPercent: fiveHour.map { remaining(usedPercent: $0.usedPercent) },
            weekRemainingPercent: week.map { remaining(usedPercent: $0.usedPercent) },
            fiveHourResetsAt: fiveHour?.resetsAt,
            weekResetsAt: week?.resetsAt,
            updatedAt: updatedAt
        )
    }

    private static func remaining(usedPercent: Double) -> Double {
        min(100, max(0, 100 - usedPercent))
    }
}
