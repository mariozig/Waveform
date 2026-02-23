import AVFoundation
import SwiftUI

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

    @Published public private(set) var sampleData: [SampleData] = []
    @Published public var displayMode: WaveformDisplayMode = .normal

    /// The viewport that the current sampleData was rendered for.
    /// Used by ClipWaveformView to apply synchronous offset correction during panning.
    @Published public private(set) var renderedViewport: TimelineViewport?

    /// How far left of screen the padded data extends (pixels).
    /// ClipWaveformView offsets the Renderer by this amount to align visible content.
    @Published public private(set) var leftPaddingPixels: CGFloat = 0

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
        lastViewport = viewport
        lastClip = clip
        lastWidth = width
        lastDisplayMode = displayMode

        generateTask?.cancel()

        // Intersect clip's timeline range with visible range
        let clipRange = clip.timelineRange
        let visibleRange = viewport.visibleRange

        guard clipRange.overlaps(visibleRange) else {
            // Clip not visible — clear
            sampleData = []
            return
        }

        // Compute the visible portion of the clip in timeline coordinates
        let visibleClipStart = max(clipRange.lowerBound, visibleRange.lowerBound)
        let visibleClipEnd = min(clipRange.upperBound, visibleRange.upperBound)

        // Expand by padding (50% of visible width each side) to cover panCorrectionOffset gaps
        let paddingSamples = visibleRange.count / 2
        let paddedClipStart = max(clipRange.lowerBound, visibleClipStart - paddingSamples)
        let paddedClipEnd = min(clipRange.upperBound, visibleClipEnd + paddingSamples)

        // Map padded range to audio file sample coordinates
        let audioStart = clip.inPoint + (paddedClipStart - clip.timelinePosition)
        let audioEnd = clip.inPoint + (paddedClipEnd - clip.timelinePosition)
        let audioRange = max(0, audioStart)..<min(audioEnd, clip.audioFrameCount)

        guard audioRange.count > 0 else {
            sampleData = []
            leftPaddingPixels = 0
            return
        }

        // Compute pixel positions for the padded range
        let paddedPixelStart = viewport.screenX(for: paddedClipStart, viewWidth: width)
        let paddedPixelEnd = viewport.screenX(for: paddedClipEnd, viewWidth: width)
        let paddedPixelWidth = Int(max(1, paddedPixelEnd - paddedPixelStart))

        // Left padding = how far left of screen the padded region starts
        let leftPad = max(0, -paddedPixelStart)

        let task = GenerateTask(audioBuffer: audioBuffer)
        generateTask = task

        let capturedViewport = viewport
        let capturedLeftPad = leftPad

        task.resume(
            width: CGFloat(paddedPixelWidth),
            audioRange: audioRange,
            displayMode: displayMode
        ) { [weak self] data in
            guard let self else { return }
            self.sampleData = data
            self.leftPaddingPixels = capturedLeftPad
            self.renderedViewport = capturedViewport
        }
    }

    public enum ClipRendererError: Error {
        case failedToCreateBuffer
    }
}
