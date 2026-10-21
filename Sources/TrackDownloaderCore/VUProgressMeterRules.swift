import Foundation

public enum VUProgressMeterZone: Equatable, Sendable {
    case green
    case amber
    case red
}

public enum VUProgressMeterRules {
    public static let segmentCount = 26
    public static let reducedMotionSegments: Set<Int> = [11, 12, 13]

    public static func normalizedFraction(_ fraction: Double) -> Double {
        guard fraction.isFinite else { return 0 }
        return min(max(fraction, 0), 1)
    }

    public static func filledSegmentCount(for fraction: Double) -> Int {
        let normalized = normalizedFraction(fraction)
        return min(Int((normalized * Double(segmentCount)).rounded(.down)), segmentCount)
    }

    public static func filledSegmentIndices(for fraction: Double) -> Set<Int> {
        Set(0..<filledSegmentCount(for: fraction))
    }

    public static func zone(for index: Int) -> VUProgressMeterZone {
        switch index {
        case 0..<16: .green
        case 16..<22: .amber
        default: .red
        }
    }

    public static func activeSegmentIndices(for phase: Int) -> Set<Int> {
        let start = ((phase % segmentCount) + segmentCount) % segmentCount
        return Set((0..<3).map { (start + $0) % segmentCount })
    }
}
