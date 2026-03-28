import AVFoundation
import SwiftUI

/// An object that generates waveform data from an `AVAudioFile` or synthetic sample data.
public class WaveformGenerator: ObservableObject {
    /// The audio file initially used to create the generator (nil for synthetic data).
    public let audioFile: AVAudioFile?
    /// An audio buffer containing the original audio file decoded as PCM data (nil for synthetic data).
    public let audioBuffer: AVAudioPCMBuffer?

    /// Number of silent samples to prepend virtually (for time alignment).
    public private(set) var samplesToPrepend: Int
    /// Number of silent samples to append virtually (for length equalization).
    public private(set) var samplesToAppend: Int
    /// Global total samples for consistent scaling across all waveforms.
    public var globalTotalSamples: Int? {
        didSet { refreshData() }
    }

    /// Total samples including virtual padding.
    public var totalVirtualSamples: Int {
        if let audioBuffer {
            return Int(audioBuffer.frameLength) + samplesToPrepend + samplesToAppend
        }
        // Synthetic mode: use renderSamples range
        return renderSamples.upperBound
    }

    /// Effective total for scaling (uses global if set, otherwise local).
    public var effectiveTotalSamples: Int {
        globalTotalSamples ?? totalVirtualSamples
    }

    /// Normalized visible range start (0-1)
    public var visibleRangeStart: CGFloat {
        guard effectiveTotalSamples > 0 else { return 0 }
        return CGFloat(renderSamples.lowerBound) / CGFloat(effectiveTotalSamples)
    }

    /// Normalized visible range end (0-1)
    public var visibleRangeEnd: CGFloat {
        guard effectiveTotalSamples > 0 else { return 1 }
        return CGFloat(renderSamples.upperBound) / CGFloat(effectiveTotalSamples)
    }

    /// Whether currently at an edge (for rubber band effect)
    public var isAtLeadingEdge: Bool { renderSamples.lowerBound == 0 }
    public var isAtTrailingEdge: Bool { renderSamples.upperBound == effectiveTotalSamples }

    private var generateTask: GenerateTask?
    @Published private(set) var sampleData: [SampleData] = []

    /// Display mode for waveform visualization.
    @Published public var displayMode: WaveformDisplayMode = .normal {
        didSet { refreshData() }
    }

    /// The range of samples to display. The value will update as the waveform is zoomed and panned.
    @Published public var renderSamples: SampleRange {
        didSet { refreshData() }
    }

    var width: CGFloat = 0 {     // would publishing this be bad?
        didSet { refreshData() }
    }

    /// Creates an instance from an `AVAudioFile` with optional virtual padding.
    /// - Parameters:
    ///   - audioFile: The audio file to generate waveform data from.
    ///   - samplesToPrepend: Number of silent samples to prepend virtually.
    ///   - samplesToAppend: Number of silent samples to append virtually.
    ///   - globalTotalSamples: Global total for consistent scaling across waveforms.
    public init?(
        audioFile: AVAudioFile,
        samplesToPrepend: Int = 0,
        samplesToAppend: Int = 0,
        globalTotalSamples: Int? = nil
    ) {
        let capacity = AVAudioFrameCount(audioFile.length)
        guard let audioBuffer = AVAudioPCMBuffer(pcmFormat: audioFile.processingFormat, frameCapacity: capacity) else { return nil }

        do {
            try audioFile.read(into: audioBuffer)
        } catch let error {
            print(error.localizedDescription)
            return nil
        }

        self.audioFile = audioFile
        self.audioBuffer = audioBuffer
        self.samplesToPrepend = samplesToPrepend
        self.samplesToAppend = samplesToAppend
        self.globalTotalSamples = globalTotalSamples
        let localTotal = Int(capacity) + samplesToPrepend + samplesToAppend
        self.renderSamples = 0..<(globalTotalSamples ?? localTotal)
    }

    /// Asynchronously creates an instance, loading audio data on a background thread.
    public static func loadAsync(
        url: URL,
        samplesToPrepend: Int = 0,
        samplesToAppend: Int = 0,
        globalTotalSamples: Int? = nil
    ) async throws -> WaveformGenerator {
        // Heavy work on background thread
        let result: (AVAudioFile, AVAudioPCMBuffer, AVAudioFrameCount) = try await Task.detached(priority: .userInitiated) {
            let audioFile = try AVAudioFile(forReading: url)
            let capacity = AVAudioFrameCount(audioFile.length)
            guard let audioBuffer = AVAudioPCMBuffer(
                pcmFormat: audioFile.processingFormat,
                frameCapacity: capacity
            ) else {
                throw LoadError.failedToCreateBuffer
            }
            try audioFile.read(into: audioBuffer)
            return (audioFile, audioBuffer, capacity)
        }.value
        let (audioFile, audioBuffer, capacity) = result

        // Create generator on main actor
        return await MainActor.run {
            let localTotal = Int(capacity) + samplesToPrepend + samplesToAppend
            return WaveformGenerator(
                audioFile: audioFile,
                audioBuffer: audioBuffer,
                samplesToPrepend: samplesToPrepend,
                samplesToAppend: samplesToAppend,
                globalTotalSamples: globalTotalSamples,
                renderSamples: 0..<(globalTotalSamples ?? localTotal)
            )
        }
    }

    public enum LoadError: Error {
        case failedToCreateBuffer
    }

    /// Private initializer for async loading path
    private init(
        audioFile: AVAudioFile,
        audioBuffer: AVAudioPCMBuffer,
        samplesToPrepend: Int,
        samplesToAppend: Int,
        globalTotalSamples: Int?,
        renderSamples: SampleRange
    ) {
        self.audioFile = audioFile
        self.audioBuffer = audioBuffer
        self.samplesToPrepend = samplesToPrepend
        self.samplesToAppend = samplesToAppend
        self.globalTotalSamples = globalTotalSamples
        self.renderSamples = renderSamples
    }
    
    func refreshData() {
        // Synthetic generators have pre-set sampleData — no regeneration needed.
        guard let audioBuffer else { return }

        generateTask?.cancel()
        guard width > 0 else { return }
        generateTask = GenerateTask(
            audioBuffer: audioBuffer,
            samplesToPrepend: samplesToPrepend,
            samplesToAppend: samplesToAppend
        )

        generateTask?.resume(width: width, renderSamples: renderSamples, displayMode: displayMode) { sampleData in
            self.sampleData = sampleData
        }
    }

    /// Updates the virtual padding without reloading the audio buffer.
    /// Shifts renderSamples to keep viewing the same audio portion.
    public func updatePadding(samplesToPrepend: Int, samplesToAppend: Int) {
        let prependDelta = samplesToPrepend - self.samplesToPrepend
        self.samplesToPrepend = samplesToPrepend
        self.samplesToAppend = samplesToAppend

        // Shift renderSamples to keep viewing the same audio portion
        let newStart = max(0, renderSamples.lowerBound + prependDelta)
        let newEnd = min(newStart + renderSamples.count, totalVirtualSamples)
        renderSamples = newStart..<newEnd
    }

    /// Updates padding and regenerates waveform WITHOUT shifting renderSamples.
    /// This causes the audio to visually shift within the viewport.
    public func resetPadding(samplesToPrepend: Int, samplesToAppend: Int) {
        self.samplesToPrepend = samplesToPrepend
        self.samplesToAppend = samplesToAppend
        refreshData()
    }

    /// Restores padding and renderSamples to specific values (used for revert).
    public func restoreState(samplesToPrepend: Int, samplesToAppend: Int, renderSamples: Range<Int>) {
        self.samplesToPrepend = samplesToPrepend
        self.samplesToAppend = samplesToAppend
        self.renderSamples = renderSamples
    }

    // MARK: Conversions
    func position(of sample: Int) -> CGFloat {
        let radio = width / CGFloat(renderSamples.count)
        return CGFloat(sample - renderSamples.lowerBound) * radio
    }
    
    func sample(for position: CGFloat) -> Int {
        guard width > 0 else { return renderSamples.lowerBound }
        let ratio = CGFloat(renderSamples.count) / width
        let sample = renderSamples.lowerBound + Int(position * ratio)
        return min(max(0, sample), effectiveTotalSamples)
    }

    func sample(_ oldSample: Int, with offset: CGFloat) -> Int {
        guard width > 0 else { return oldSample }
        let ratio = CGFloat(renderSamples.count) / width
        let sample = oldSample + Int(offset * ratio)
        return min(max(0, sample), effectiveTotalSamples)
    }

    // MARK: - Synthetic Data

    /// Creates a generator with pre-built sample data, no audio file required.
    /// Use this for decorative waveforms (e.g., Apple Music frequency bars)
    /// where real audio data is unavailable but you still want the full
    /// handle/selection/highlight UI.
    ///
    /// - Parameters:
    ///   - sampleData: Pre-built sample data for rendering. The count determines
    ///     the visual width in samples.
    ///   - totalSamples: Total logical sample count (determines handle positioning
    ///     and selection range). Typically `sampleRate * duration`.
    public init(syntheticSamples sampleData: [SampleData], totalSamples: Int) {
        self.audioFile = nil
        self.audioBuffer = nil
        self.samplesToPrepend = 0
        self.samplesToAppend = 0
        self.globalTotalSamples = nil
        self.renderSamples = 0..<totalSamples
        self.sampleData = sampleData
    }

    // MARK: - Preview Support

    /// Creates a WaveformGenerator with synthetic audio data for SwiftUI previews.
    /// Generates a waveform pattern resembling real audio.
    public static func preview(duration: TimeInterval = 10, sampleRate: Int = 44100) -> WaveformGenerator? {
        let frameCount = Int(duration * Double(sampleRate))
        let format = AVAudioFormat(standardFormatWithSampleRate: Double(sampleRate), channels: 1)!

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)) else {
            return nil
        }
        buffer.frameLength = AVAudioFrameCount(frameCount)

        // Generate synthetic waveform resembling audio
        if let channelData = buffer.floatChannelData?[0] {
            for i in 0..<frameCount {
                let t = Float(i) / Float(sampleRate)
                // Mix of frequencies for interesting waveform shape
                let base = sin(t * 440 * 2 * .pi) * 0.3
                let harmonic = sin(t * 880 * 2 * .pi) * 0.15
                let sub = sin(t * 110 * 2 * .pi) * 0.2
                // Amplitude envelope (fade in/out with variation)
                let envelope = min(1, Float(i) / 4410) * min(1, Float(frameCount - i) / 4410)
                let variation = 0.5 + 0.5 * sin(t * 2 * .pi * 0.5)
                channelData[i] = (base + harmonic + sub) * envelope * Float(variation)
            }
        }

        // Write to temp file (AVAudioFile requires a file)
        // Use static filename to avoid accumulating temp files during development
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("waveform_preview.caf")
        try? FileManager.default.removeItem(at: tempURL)
        do {
            let audioFile = try AVAudioFile(forWriting: tempURL, settings: format.settings)
            try audioFile.write(from: buffer)
            // Re-open for reading
            let readFile = try AVAudioFile(forReading: tempURL)
            return WaveformGenerator(audioFile: readFile)
        } catch {
            print("Preview audio generation failed: \(error)")
            return nil
        }
    }
}
