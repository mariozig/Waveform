import Foundation

/// The computed render range for a clip given a viewport.
/// Encapsulates the intersection math so it can be tested independently.
public struct ClipRenderRange {
    /// The padded timeline start sample (may be before visible range).
    public let paddedTimelineStart: Int
    /// The audio file sample range to render.
    public let audioRange: Range<Int>
    /// The pixel width to render into.
    public let pixelWidth: Int
    /// Samples per pixel for this render.
    public let samplesPerPixel: Double
}

/// Computes the render range for a clip given a viewport and view width.
/// Returns nil if the clip is not visible or there's nothing to render.
public func clipRenderRange(
    clip: ClipDescriptor,
    viewport: TimelineViewport,
    viewWidth: CGFloat
) -> ClipRenderRange? {
    guard viewWidth > 0 else { return nil }

    let clipRange = clip.timelineRange
    let visibleRange = viewport.visibleRange

    guard clipRange.overlaps(visibleRange) else { return nil }

    // Intersect clip with visible range
    let visibleClipStart = max(clipRange.lowerBound, visibleRange.lowerBound)
    let visibleClipEnd = min(clipRange.upperBound, visibleRange.upperBound)

    // Expand by 150% of visible width each side to cover fast scroll
    let paddingSamples = visibleRange.count * 3 / 2
    let paddedClipStart = max(clipRange.lowerBound, visibleClipStart - paddingSamples)
    let paddedClipEnd = min(clipRange.upperBound, visibleClipEnd + paddingSamples)

    // Map padded range to audio file sample coordinates
    let audioStart = clip.inPoint + (paddedClipStart - clip.timelinePosition)
    let audioEnd = clip.inPoint + (paddedClipEnd - clip.timelinePosition)
    let audioRange = max(0, audioStart)..<min(audioEnd, clip.audioFrameCount)

    guard audioRange.count > 0 else { return nil }

    // Compute pixel width for the padded range
    let paddedPixelStart = viewport.screenX(for: paddedClipStart, viewWidth: viewWidth)
    let paddedPixelEnd = viewport.screenX(for: paddedClipEnd, viewWidth: viewWidth)
    let pixelWidth = Int(max(1, paddedPixelEnd - paddedPixelStart))
    let samplesPerPixel = Double(audioRange.count) / Double(pixelWidth)

    return ClipRenderRange(
        paddedTimelineStart: paddedClipStart,
        audioRange: audioRange,
        pixelWidth: pixelWidth,
        samplesPerPixel: samplesPerPixel
    )
}
