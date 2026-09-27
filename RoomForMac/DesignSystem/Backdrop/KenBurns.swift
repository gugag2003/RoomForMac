import CoreGraphics
import Foundation

/// The slow backdrop drift (spec §11.3): one loop every `Motion.driftPeriod`, zooming from 1.0 up to
/// 1.0 + `Motion.driftMaxScaleIncrease` and back while panning a little.
///
/// Pure math, so it can be tested. `BackdropView` feeds it the time from a `TimelineView`.
enum KenBurns {
    /// One frame of the drift: how much to scale the backdrop and how far to move it.
    struct Pose: Equatable, Sendable {
        var scale: CGFloat
        var offset: CGSize

        /// No zoom and no pan: where every loop starts, and where Reduce Motion holds the backdrop.
        static let rest = Pose(scale: 1, offset: .zero)
    }

    /// The loop length in seconds.
    static var period: TimeInterval { Motion.driftPeriod / .seconds(1) }

    /// 1.0 at the start of each loop, 1.0 + `Motion.driftMaxScaleIncrease` halfway through, eased in between.
    static func scale(at time: TimeInterval) -> CGFloat {
        1 + Motion.driftMaxScaleIncrease * (1 - cos(phase(at: time))) / 2
    }

    /// A pan along one loop of a cardioid.
    ///
    /// It reaches at most 2% of `size` on each axis. It never moves further than half of the margin the
    /// current zoom adds past each edge, so the backdrop's edge never comes into view.
    static func offset(at time: TimeInterval, in size: CGSize) -> CGSize {
        let reach = (scale(at: time) - 1) / 4
        let angle = phase(at: time)
        return CGSize(width: size.width * reach * cos(angle), height: size.height * reach * sin(angle))
    }

    /// The pose to draw: the drift, or `.rest` under Reduce Motion so the backdrop stops at once.
    static func pose(at time: TimeInterval, in size: CGSize, reduceMotion: Bool) -> Pose {
        guard !reduceMotion else { return .rest }
        return Pose(scale: scale(at: time), offset: offset(at: time, in: size))
    }

    /// The angle through the current loop, 0 ..< 2π.
    private static func phase(at time: TimeInterval) -> CGFloat {
        CGFloat(time.truncatingRemainder(dividingBy: period) / period) * 2 * .pi
    }
}
