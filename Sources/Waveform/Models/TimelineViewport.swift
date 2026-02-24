import Foundation

/// Single source of truth for what's visible in the timeline.
/// Replaces N independent `renderSamples` ranges.
public struct TimelineViewport: Equatable, Sendable {
    /// The range of timeline samples currently visible on screen.
    public var visibleRange: Range<Int>
    /// Total length of the timeline in samples.
    public var totalLength: Int

    public init(visibleRange: Range<Int>, totalLength: Int) {
        let clampedTotal = max(0, totalLength)
        let clampedLower = max(0, min(visibleRange.lowerBound, clampedTotal))
        let clampedUpper = max(clampedLower, min(visibleRange.upperBound, clampedTotal))
        self.visibleRange = clampedLower..<clampedUpper
        self.totalLength = clampedTotal
    }

    /// Creates a viewport showing the entire timeline.
    public init(totalLength: Int) {
        let clampedTotal = max(0, totalLength)
        self.visibleRange = 0..<clampedTotal
        self.totalLength = clampedTotal
    }

    // MARK: - Derived Properties

    /// Number of samples currently visible.
    public var visibleCount: Int { visibleRange.count }

    /// Normalized start position (0–1).
    public var normalizedStart: CGFloat {
        guard totalLength > 0 else { return 0 }
        return CGFloat(visibleRange.lowerBound) / CGFloat(totalLength)
    }

    /// Normalized end position (0–1).
    public var normalizedEnd: CGFloat {
        guard totalLength > 0 else { return 1 }
        return CGFloat(visibleRange.upperBound) / CGFloat(totalLength)
    }

    public var isAtLeadingEdge: Bool { visibleRange.lowerBound <= 0 }
    public var isAtTrailingEdge: Bool { visibleRange.upperBound >= totalLength }

    // MARK: - Transformations

    /// Returns a new viewport zoomed by the given factor around the center.
    /// factor > 1 zooms in, < 1 zooms out.
    /// - Parameter minVisibleCount: Floor for visible samples (prevents extreme zoom).
    public func zoomed(by factor: CGFloat, minVisibleCount: Int? = nil) -> TimelineViewport {
        guard totalLength > 0 else { return self }
        let count = visibleRange.count
        let floor = max(1, minVisibleCount ?? 1)
        let newCount = max(floor, Int(CGFloat(count) / factor))
        let center = visibleRange.lowerBound + count / 2
        let halfNew = newCount / 2

        var newStart = center - halfNew
        var newEnd = newStart + newCount

        // Clamp
        if newStart < 0 {
            newStart = 0
            newEnd = min(newCount, totalLength)
        }
        if newEnd > totalLength {
            newEnd = totalLength
            newStart = max(0, newEnd - newCount)
        }

        return TimelineViewport(visibleRange: newStart..<newEnd, totalLength: totalLength)
    }

    /// Returns a new viewport panned by the given points delta.
    /// Positive delta pans right (later in timeline), negative pans left.
    public func panned(by pointsDelta: CGFloat, viewWidth: CGFloat) -> TimelineViewport {
        guard viewWidth > 0, totalLength > 0 else { return self }
        let sampleDelta = Int(pointsDelta * CGFloat(visibleRange.count) / viewWidth)
        return pannedBySamples(sampleDelta)
    }

    /// Returns a new viewport panned by a sample count delta.
    public func pannedBySamples(_ sampleDelta: Int) -> TimelineViewport {
        guard totalLength > 0 else { return self }
        let count = visibleRange.count
        var newStart = visibleRange.lowerBound + sampleDelta
        var newEnd = newStart + count

        if newStart < 0 {
            newStart = 0
            newEnd = min(count, totalLength)
        }
        if newEnd > totalLength {
            newEnd = totalLength
            newStart = max(0, newEnd - count)
        }

        return TimelineViewport(visibleRange: newStart..<newEnd, totalLength: totalLength)
    }

    // MARK: - Coordinate Conversion

    /// Returns the screen X position for a given timeline sample.
    public func screenX(for sample: Int, viewWidth: CGFloat) -> CGFloat {
        guard visibleRange.count > 0 else { return 0 }
        return CGFloat(sample - visibleRange.lowerBound) / CGFloat(visibleRange.count) * viewWidth
    }

    /// Returns the timeline sample for a given screen X position.
    public func timelineSample(for x: CGFloat, viewWidth: CGFloat) -> Int {
        guard viewWidth > 0 else { return visibleRange.lowerBound }
        let sample = visibleRange.lowerBound + Int(x / viewWidth * CGFloat(visibleRange.count))
        return max(0, min(sample, totalLength))
    }
}
