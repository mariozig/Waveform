import AVFoundation
import SwiftUI

/// Atomic snapshot of a completed render — published as a single value
/// so SwiftUI never sees partially-updated state.
public struct RenderSnapshot: Equatable {
    public var sampleData: [SampleData]
    /// Timeline sample position of the first rendered pixel.
    public var paddedTimelineStart: Int
    /// Exact samples-per-pixel (floating point to avoid quantization jitter).
    public var samplesPerPixel: Double

    public static let empty = RenderSnapshot(sampleData: [], paddedTimelineStart: 0, samplesPerPixel: 1)

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.paddedTimelineStart == rhs.paddedTimelineStart
            && lhs.samplesPerPixel == rhs.samplesPerPixel
            && lhs.sampleData.count == rhs.sampleData.count
    }
}

/// Renders audio for a clip given a viewport. Does not own viewport state.
/// Replaces `WaveformGenerator` — viewport is externally driven.
@MainActor
public class ClipRenderer: ObservableObject {
    /// The loaded audio buffer (nil until loadAsync completes).
    public private(set) var audioBuffer: AVAudioPCMBuffer?
    /// Frame count of the loaded audio.
    public private(set) var audioFrameCount: Int = 0
    /// Sample rate of the loaded audio.
    public private(set) var audioSampleRate: Int = 0

    /// Single atomic snapshot of the latest render output.
    @Published public private(set) var snapshot: RenderSnapshot = .empty

    @Published public var displayMode: WaveformDisplayMode = .normal

    private var loadTask: Task<(AVAudioPCMBuffer, Int, Int), any Error>?
    private var generateTask: GenerateTask?
    private var lastViewport: TimelineViewport?
    private var lastClip: ClipDescriptor?
    private var lastWidth: CGFloat = 0
    private var lastDisplayMode: WaveformDisplayMode = .normal

    public init() {}

    // MARK: - Loading

    /// Loads audio from a URL on a background thread.
    /// Cancels any in-flight load before starting.
    public func loadAsync(url: URL) async throws {
        loadTask?.cancel()
        let task = Task.detached(priority: .userInitiated) {
            let audioFile = try AVAudioFile(forReading: url)
            let capacity = AVAudioFrameCount(audioFile.length)
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: audioFile.processingFormat,
                frameCapacity: capacity
            ) else {
                throw ClipRendererError.failedToCreateBuffer
            }
            try audioFile.read(into: buffer)
            return (buffer, Int(capacity), Int(audioFile.processingFormat.sampleRate))
        }
        loadTask = task
        let (buffer, frameCount, sampleRate) = try await task.value

        guard !Task.isCancelled else { return }
        self.audioBuffer = buffer
        self.audioFrameCount = frameCount
        self.audioSampleRate = sampleRate
    }

    public var isLoaded: Bool { audioBuffer != nil }

    // MARK: - Rendering

    /// Updates the render for the given viewport and clip descriptor.
    /// Call whenever viewport, clip, or view width changes.
    public func update(viewport: TimelineViewport, clip: ClipDescriptor, width: CGFloat) {
        guard width > 0, let audioBuffer else { return }

        // Skip if nothing changed
        if viewport == lastViewport && clip == lastClip && width == lastWidth && displayMode == lastDisplayMode {
            return
        }

        let clipChanged = clip != lastClip
        let displayModeChanged = displayMode != lastDisplayMode
        let widthChanged = width != lastWidth

        lastViewport = viewport
        lastClip = clip
        lastWidth = width
        lastDisplayMode = displayMode

        // Intersect clip's timeline range with visible range
        let clipRange = clip.timelineRange
        let visibleRange = viewport.visibleRange

        guard clipRange.overlaps(visibleRange) else {
            // Clip not visible — clear
            generateTask?.cancel()
            snapshot = .empty
            return
        }

        // Check if the existing render still covers the visible range with adequate resolution.
        // If so, skip re-rendering — the correction transform handles viewport changes smoothly.
        if !clipChanged && !displayModeChanged && !widthChanged && snapshot.sampleData.count > 0 {
            let snap = snapshot
            let renderedEnd = snap.paddedTimelineStart + Int(Double(snap.sampleData.count) * snap.samplesPerPixel)
            let visibleCovered = snap.paddedTimelineStart <= visibleRange.lowerBound
                && renderedEnd >= visibleRange.upperBound

            // Check zoom: current ideal spp vs rendered spp
            let idealSpp = Double(visibleRange.count) / Double(width)
            let zoomRatio = snap.samplesPerPixel / idealSpp
            // Re-render if zoom changed by >2x in either direction, or if panned beyond buffer
            let zoomOk = zoomRatio > 0.5 && zoomRatio < 2.0

            if visibleCovered && zoomOk {
                return
            }
        }

        generateTask?.cancel()

        // Compute the visible portion of the clip in timeline coordinates
        let visibleClipStart = max(clipRange.lowerBound, visibleRange.lowerBound)
        let visibleClipEnd = min(clipRange.upperBound, visibleRange.upperBound)

        // Expand by padding (50% of visible width each side) to cover pan buffer
        let paddingSamples = visibleRange.count / 2
        let paddedClipStart = max(clipRange.lowerBound, visibleClipStart - paddingSamples)
        let paddedClipEnd = min(clipRange.upperBound, visibleClipEnd + paddingSamples)

        // Map padded range to audio file sample coordinates
        let audioStart = clip.inPoint + (paddedClipStart - clip.timelinePosition)
        let audioEnd = clip.inPoint + (paddedClipEnd - clip.timelinePosition)
        let audioRange = max(0, audioStart)..<min(audioEnd, clip.audioFrameCount)

        guard audioRange.count > 0 else {
            snapshot = .empty
            return
        }

        // Compute pixel positions for the padded range
        let paddedPixelStart = viewport.screenX(for: paddedClipStart, viewWidth: width)
        let paddedPixelEnd = viewport.screenX(for: paddedClipEnd, viewWidth: width)
        let paddedPixelWidth = Int(max(1, paddedPixelEnd - paddedPixelStart))

        let task = GenerateTask(audioBuffer: audioBuffer)
        generateTask = task

        let capturedPaddedStart = paddedClipStart
        let capturedSpp = Double(audioRange.count) / Double(paddedPixelWidth)

        task.resume(
            width: CGFloat(paddedPixelWidth),
            audioRange: audioRange,
            displayMode: displayMode
        ) { [weak self] data in
            guard let self else { return }
            self.snapshot = RenderSnapshot(
                sampleData: data,
                paddedTimelineStart: capturedPaddedStart,
                samplesPerPixel: capturedSpp
            )
        }
    }

    public enum ClipRendererError: Error {
        case failedToCreateBuffer
    }
}
