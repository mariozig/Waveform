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

    /// Compares metadata only (not sample contents) to avoid O(n) array comparisons.
    /// Safe because re-renders always produce different paddedTimelineStart or samplesPerPixel.
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
    private var renderGeneration: Int = 0
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

    /// Cancels any in-flight render task.
    public func cancelRender() {
        generateTask?.cancel()
    }

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

        guard let renderRange = clipRenderRange(clip: clip, viewport: viewport, viewWidth: width) else {
            snapshot = .empty
            return
        }

        renderGeneration += 1
        let expectedGeneration = renderGeneration

        let task = GenerateTask(audioBuffer: audioBuffer)
        generateTask = task

        task.resume(
            width: CGFloat(renderRange.pixelWidth),
            audioRange: renderRange.audioRange,
            displayMode: displayMode
        ) { [weak self] data in
            Task { @MainActor [weak self] in
                guard let self, self.renderGeneration == expectedGeneration else { return }
                self.snapshot = RenderSnapshot(
                    sampleData: data,
                    paddedTimelineStart: renderRange.paddedTimelineStart,
                    samplesPerPixel: renderRange.samplesPerPixel
                )
            }
        }
    }

    public enum ClipRendererError: Error {
        case failedToCreateBuffer
    }
}
