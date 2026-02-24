import Foundation

/// Describes a clip's position and extent in the timeline.
/// Replaces padding-as-positioning (samplesToPrepend/samplesToAppend).
public struct ClipDescriptor: Equatable, Sendable {
    /// Start sample in timeline coordinates (maps from samplesToPrepend).
    public var timelinePosition: Int
    /// Trim start within the audio file (future: trimming support).
    public var inPoint: Int
    /// Total frames in the audio file.
    public var audioFrameCount: Int
    /// Sample rate of the audio file.
    public var sampleRate: Int

    public init(
        timelinePosition: Int,
        inPoint: Int = 0,
        audioFrameCount: Int,
        sampleRate: Int
    ) {
        self.timelinePosition = timelinePosition
        self.inPoint = inPoint
        self.audioFrameCount = audioFrameCount
        self.sampleRate = sampleRate
    }

    /// Duration of the clip in timeline samples (from inPoint to end).
    public var timelineDuration: Int {
        max(0, audioFrameCount - inPoint)
    }

    /// End position in timeline coordinates.
    public var timelineEndPosition: Int {
        timelinePosition + timelineDuration
    }

    /// The range this clip occupies in timeline coordinates.
    public var timelineRange: Range<Int> {
        timelinePosition..<timelineEndPosition
    }

}
