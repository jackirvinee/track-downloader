import TrackDownloaderCore
import SwiftUI

struct VUProgressMeter: View {
    let fractionCompleted: Double?
    let stageLabel: String

    private let normalizedFraction: Double?

    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    #if DEBUG
    @Environment(\.trackDownloaderFixtureReduceMotion) private var fixtureReduceMotion
    #endif

    init(fractionCompleted: Double?, stageLabel: String) {
        self.fractionCompleted = fractionCompleted
        self.stageLabel = stageLabel
        normalizedFraction = fractionCompleted.map(VUProgressMeterRules.normalizedFraction)
    }

    var body: some View {
        TimelineView(
            .animation(
                minimumInterval: 0.14,
                paused: reduceMotion || normalizedFraction != nil
            )
        ) { context in
            let filledSegments = filledSegments(for: context.date)
            let segmentAnimation: Animation? = normalizedFraction == nil
                ? nil
                : .easeOut(duration: 0.18)

            HStack(spacing: 2) {
                ForEach(0..<VUProgressMeterRules.segmentCount, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(segmentColor(for: index, filledSegments: filledSegments))
                        .overlay {
                            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
                        }
                        .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 10, maxHeight: 10)
            .animation(segmentAnimation, value: filledSegments)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Download progress")
            .accessibilityValue(accessibilityValue)
        }
    }

    private var reduceMotion: Bool {
        #if DEBUG
        accessibilityReduceMotion || fixtureReduceMotion
        #else
        accessibilityReduceMotion
        #endif
    }

    private var accessibilityValue: String {
        if let normalizedFraction {
            return normalizedFraction.formatted(
                .percent.precision(.fractionLength(0))
            )
        }
        return stageLabel
    }

    private func filledSegments(for date: Date) -> Set<Int> {
        if let normalizedFraction {
            return VUProgressMeterRules.filledSegmentIndices(for: normalizedFraction)
        }
        if reduceMotion {
            return VUProgressMeterRules.reducedMotionSegments
        }

        let phase = Int((date.timeIntervalSinceReferenceDate / 0.14).rounded(.down))
        return VUProgressMeterRules.activeSegmentIndices(for: phase)
    }

    private func segmentColor(for index: Int, filledSegments: Set<Int>) -> Color {
        guard filledSegments.contains(index) else {
            return Color.secondary.opacity(0.22)
        }

        switch VUProgressMeterRules.zone(for: index) {
        case .green:
            return Color(red: 77 / 255, green: 203 / 255, blue: 120 / 255)
        case .amber:
            return Color(red: 231 / 255, green: 164 / 255, blue: 59 / 255)
        case .red:
            return Color(red: 224 / 255, green: 92 / 255, blue: 88 / 255)
        }
    }
}
