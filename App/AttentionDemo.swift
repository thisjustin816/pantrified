#if DEBUG
import Foundation
import PantrifiedDomain

/// Runs the domain attention policy on one fixed package, so a Debug build shows the packages
/// linked and working on the Apple SDK. Compiled out of Release.
enum AttentionDemo {
    struct Sample {
        let name: String
        let state: AttentionState

        var stateLabel: String {
            switch state {
            case .unknown: "Unknown"
            case .fine: "Fine"
            case .useSoon: "Use soon"
            case .pastGuidance: "Past guidance"
            }
        }
    }

    static func sample(now: Date = Date()) -> Sample {
        let package = Package(
            spaceID: SpaceID(),
            name: "Spinach",
            location: LocationID(),
            printedDate: PrintedDate(label: .useBy, date: now.addingTimeInterval(2 * 86_400)),
            addedAt: now
        )
        let assessment = AttentionPolicy().assess(
            package, storageType: .refrigerated, guidance: nil, now: now
        )
        return Sample(name: package.name, state: assessment.state)
    }
}
#endif
