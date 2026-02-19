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

    private var generateTask: GenerateTask?
    private var lastViewport: TimelineViewport?
    private var lastClip: ClipDescriptor?
    private var lastWidth: CGFloat = 0
    private var lastDisplayMode: WaveformDisplayMode = .normal

    public init() {}

    // MARK: - Loading

    /// Loads audio from a URL on a background thread.
    public func loadAsync(url: URL) async throws {
        let (buffer, frameCount, sampleRate) = try await Task.detached(priority: .userInitiated) {
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
        }.value

        await MainActor.run {
            self.audioBuffer = buffer
            self.audioFrameCount = frameCount
            self.audioSampleRate = sampleRate
        }
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

        // Map to audio file sample coordinates
        let audioStart = clip.inPoint + (visibleClipStart - clip.timelinePosition)
        let audioEnd = clip.inPoint + (visibleClipEnd - clip.timelinePosition)
        let audioRange = max(0, audioStart)..<min(audioEnd, clip.audioFrameCount)

        guard audioRange.count > 0 else {
            sampleData = []
            return
        }

        // Compute pixel range within the view
        let pixelStart = viewport.screenX(for: visibleClipStart, viewWidth: width)
        let pixelEnd = viewport.screenX(for: visibleClipEnd, viewWidth: width)
        let pixelWidth = Int(max(1, pixelEnd - pixelStart))

        let task = GenerateTask(audioBuffer: audioBuffer)
        generateTask = task

        task.resume(
            width: CGFloat(pixelWidth),
            audioRange: audioRange,
            displayMode: displayMode
        ) { [weak self] data in
            guard let self else { return }

            // Build full-width sample data with the clip portion at the correct offset
            let totalPixels = Int(width)
            let startPixel = max(0, Int(pixelStart))

            if startPixel == 0 && data.count == totalPixels {
                self.sampleData = data
            } else {
                var fullData = [SampleData](repeating: .zero, count: totalPixels)
                let copyCount = min(data.count, totalPixels - startPixel)
                for i in 0..<copyCount {
                    fullData[startPixel + i] = data[i]
                }
                self.sampleData = fullData
            }
        }
    }

    public enum ClipRendererError: Error {
        case failedToCreateBuffer
    }
}
