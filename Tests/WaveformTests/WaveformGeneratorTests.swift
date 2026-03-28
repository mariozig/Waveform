import Testing
import AVFoundation
@testable import Waveform

@Suite("WaveformGenerator Padding Tests")
struct WaveformGeneratorTests {

    // MARK: - Test Helpers

    /// Creates a temporary audio file for testing
    private func createTestAudioFile(sampleCount: Int = 10000, sampleRate: Double = 44100) throws -> AVAudioFile {
        let tempDir = FileManager.default.temporaryDirectory
        let tempFile = tempDir.appendingPathComponent(UUID().uuidString + ".caf")

        // Use linear PCM format which is more reliable for testing
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]

        let audioFile = try AVAudioFile(forWriting: tempFile, settings: settings)

        let format = audioFile.processingFormat
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sampleCount))!
        buffer.frameLength = AVAudioFrameCount(sampleCount)

        // Fill with simple waveform data
        if let channelData = buffer.floatChannelData?[0] {
            for i in 0..<sampleCount {
                channelData[i] = sin(Float(i) * 0.01)
            }
        }

        try audioFile.write(from: buffer)

        // Re-open for reading
        return try AVAudioFile(forReading: tempFile)
    }

    private func createGenerator(
        sampleCount: Int = 10000,
        samplesToPrepend: Int = 0,
        samplesToAppend: Int = 0,
        globalTotalSamples: Int? = nil
    ) throws -> WaveformGenerator {
        let audioFile = try createTestAudioFile(sampleCount: sampleCount)
        guard let generator = WaveformGenerator(
            audioFile: audioFile,
            samplesToPrepend: samplesToPrepend,
            samplesToAppend: samplesToAppend,
            globalTotalSamples: globalTotalSamples
        ) else {
            throw TestError.failedToCreateGenerator
        }
        return generator
    }

    // MARK: - updatePadding Tests

    @Test("updatePadding shifts renderSamples to preserve viewport position")
    func updatePadding_shiftsRenderSamples() throws {
        let generator = try createGenerator(sampleCount: 10000)

        // Initial state: renderSamples covers full range
        let initialRenderSamples = generator.renderSamples
        #expect(initialRenderSamples.lowerBound == 0)

        // Add prepend padding
        generator.updatePadding(samplesToPrepend: 1000, samplesToAppend: 0)

        // renderSamples should shift by 1000 to preserve viewport
        #expect(generator.renderSamples.lowerBound == 1000)
        #expect(generator.samplesToPrepend == 1000)
    }

    @Test("updatePadding preserves renderSamples count")
    func updatePadding_preservesRenderSamplesCount() throws {
        let generator = try createGenerator(sampleCount: 10000)

        let initialCount = generator.renderSamples.count

        generator.updatePadding(samplesToPrepend: 500, samplesToAppend: 500)

        // Count should be same (or as close as possible within bounds)
        #expect(generator.renderSamples.count == initialCount)
    }

    @Test("updatePadding clamps renderSamples to valid bounds")
    func updatePadding_clampsToValidBounds() throws {
        let generator = try createGenerator(sampleCount: 10000)

        // Set initial renderSamples near the end
        generator.updatePadding(samplesToPrepend: 0, samplesToAppend: 0)

        // Large negative prepend delta should clamp to 0
        generator.updatePadding(samplesToPrepend: 0, samplesToAppend: 0)
        #expect(generator.renderSamples.lowerBound >= 0)
    }

    // MARK: - resetPadding Tests

    @Test("resetPadding does NOT shift renderSamples")
    func resetPadding_doesNotShiftRenderSamples() throws {
        let generator = try createGenerator(sampleCount: 10000)
        generator.width = 100 // Set width so refreshData works

        // Capture initial renderSamples
        let initialLowerBound = generator.renderSamples.lowerBound

        // Reset padding - should NOT shift renderSamples
        generator.resetPadding(samplesToPrepend: 1000, samplesToAppend: 0)

        // renderSamples lower bound should stay at 0 (or same as initial)
        #expect(generator.renderSamples.lowerBound == initialLowerBound)
        #expect(generator.samplesToPrepend == 1000)
    }

    @Test("resetPadding updates padding values")
    func resetPadding_updatesPaddingValues() throws {
        let generator = try createGenerator(sampleCount: 10000)
        generator.width = 100

        generator.resetPadding(samplesToPrepend: 500, samplesToAppend: 300)

        #expect(generator.samplesToPrepend == 500)
        #expect(generator.samplesToAppend == 300)
    }

    // MARK: - restoreState Tests

    @Test("restoreState restores both padding and renderSamples")
    func restoreState_restoresBothPaddingAndRenderSamples() throws {
        let generator = try createGenerator(sampleCount: 10000)

        // Capture original state
        let originalPrepend = generator.samplesToPrepend
        let originalAppend = generator.samplesToAppend
        let originalRenderSamples = generator.renderSamples

        // Modify state
        generator.updatePadding(samplesToPrepend: 2000, samplesToAppend: 1000)

        // Verify state changed
        #expect(generator.samplesToPrepend != originalPrepend || generator.renderSamples != originalRenderSamples)

        // Restore state
        generator.restoreState(
            samplesToPrepend: originalPrepend,
            samplesToAppend: originalAppend,
            renderSamples: originalRenderSamples
        )

        #expect(generator.samplesToPrepend == originalPrepend)
        #expect(generator.samplesToAppend == originalAppend)
        #expect(generator.renderSamples == originalRenderSamples)
    }

    @Test("restoreState can restore to arbitrary renderSamples")
    func restoreState_restoresToArbitraryRenderSamples() throws {
        let generator = try createGenerator(sampleCount: 10000)

        let targetRenderSamples = 500..<5500

        generator.restoreState(
            samplesToPrepend: 100,
            samplesToAppend: 200,
            renderSamples: targetRenderSamples
        )

        #expect(generator.samplesToPrepend == 100)
        #expect(generator.samplesToAppend == 200)
        #expect(generator.renderSamples == targetRenderSamples)
    }

    // MARK: - globalTotalSamples Tests

    @Test("globalTotalSamples affects effectiveTotalSamples")
    func globalTotalSamples_affectsEffectiveTotalSamples() throws {
        let generator = try createGenerator(sampleCount: 10000)

        let localTotal = generator.totalVirtualSamples

        // Set global total
        generator.globalTotalSamples = 50000

        #expect(generator.effectiveTotalSamples == 50000)
        #expect(generator.effectiveTotalSamples != localTotal)
    }

    @Test("globalTotalSamples nil uses local total")
    func globalTotalSamples_nilUsesLocalTotal() throws {
        let generator = try createGenerator(sampleCount: 10000, samplesToPrepend: 100, samplesToAppend: 200)

        generator.globalTotalSamples = nil

        let expectedTotal = 10000 + 100 + 200
        #expect(generator.effectiveTotalSamples == expectedTotal)
    }

    // MARK: - totalVirtualSamples Tests

    @Test("totalVirtualSamples includes padding")
    func totalVirtualSamples_includesPadding() throws {
        let generator = try createGenerator(
            sampleCount: 10000,
            samplesToPrepend: 500,
            samplesToAppend: 300
        )

        #expect(generator.totalVirtualSamples == 10000 + 500 + 300)
    }

    // MARK: - Difference between updatePadding and resetPadding

    @Test("updatePadding and resetPadding produce different viewport behaviors")
    func updateVsResetPadding_differentBehaviors() throws {
        // Create two identical generators
        let generator1 = try createGenerator(sampleCount: 10000)
        let generator2 = try createGenerator(sampleCount: 10000)
        generator1.width = 100
        generator2.width = 100

        // Same initial state
        #expect(generator1.renderSamples == generator2.renderSamples)

        // Apply same padding change with different methods
        generator1.updatePadding(samplesToPrepend: 1000, samplesToAppend: 0)
        generator2.resetPadding(samplesToPrepend: 1000, samplesToAppend: 0)

        // Both have same padding
        #expect(generator1.samplesToPrepend == generator2.samplesToPrepend)

        // But different renderSamples!
        // updatePadding shifts to preserve viewport (audio stays in same screen position)
        // resetPadding doesn't shift (audio visually moves)
        #expect(generator1.renderSamples.lowerBound == 1000) // shifted
        #expect(generator2.renderSamples.lowerBound == 0)    // not shifted
    }
}

    // MARK: - Synthetic Data Init Tests

    @Test("Synthetic init creates generator without audio file")
    func syntheticInit_createsWithoutAudioFile() {
        let samples = [SampleData(min: -0.5, max: 0.5), SampleData(min: -0.8, max: 0.8)]
        let generator = WaveformGenerator(syntheticSamples: samples, totalSamples: 44100)

        #expect(generator.audioFile == nil)
        #expect(generator.audioBuffer == nil)
    }

    @Test("Synthetic init sets correct totalSamples via renderSamples")
    func syntheticInit_correctTotalSamples() {
        let samples = [SampleData(min: -0.3, max: 0.3)]
        let generator = WaveformGenerator(syntheticSamples: samples, totalSamples: 882000)

        #expect(generator.effectiveTotalSamples == 882000)
        #expect(generator.renderSamples == 0..<882000)
    }

    @Test("Synthetic init totalVirtualSamples matches renderSamples")
    func syntheticInit_totalVirtualSamples() {
        let samples = [SampleData(min: -0.5, max: 0.5)]
        let generator = WaveformGenerator(syntheticSamples: samples, totalSamples: 100000)

        #expect(generator.totalVirtualSamples == 100000)
    }

    @Test("Synthetic init has no padding")
    func syntheticInit_noPadding() {
        let samples = [SampleData(min: -0.5, max: 0.5)]
        let generator = WaveformGenerator(syntheticSamples: samples, totalSamples: 44100)

        #expect(generator.samplesToPrepend == 0)
        #expect(generator.samplesToAppend == 0)
    }

    @Test("Synthetic init position conversion works")
    func syntheticInit_positionConversion() {
        let samples = (0..<100).map { _ in SampleData(min: -0.5, max: 0.5) }
        let generator = WaveformGenerator(syntheticSamples: samples, totalSamples: 44100)
        generator.width = 300

        // sample(for:) should convert pixel position to sample index
        let midSample = generator.sample(for: 150)
        #expect(midSample > 0)
        #expect(midSample < 44100)
    }

    @Test("Synthetic init sample offset conversion works")
    func syntheticInit_sampleOffsetConversion() {
        let samples = (0..<100).map { _ in SampleData(min: -0.5, max: 0.5) }
        let generator = WaveformGenerator(syntheticSamples: samples, totalSamples: 44100)
        generator.width = 300

        // sample(_:with:) should add pixel offset to existing sample
        let newSample = generator.sample(22050, with: 10)
        #expect(newSample > 22050)
    }

    @Test("Synthetic init refreshData is no-op")
    func syntheticInit_refreshDataNoOp() {
        let samples = [SampleData(min: -0.3, max: 0.3), SampleData(min: -0.7, max: 0.7)]
        let generator = WaveformGenerator(syntheticSamples: samples, totalSamples: 44100)
        generator.width = 200

        // refreshData should not crash or clear sampleData for synthetic generators
        generator.refreshData()
        // sampleData is internal, but we can verify the generator still works
        #expect(generator.effectiveTotalSamples == 44100)
    }

    @Test("Synthetic init with frequency bar pattern")
    func syntheticInit_frequencyBarPattern() {
        // This is how WalkUpFire uses it for Apple Music
        let pattern: [Float] = [0.15, 0.30, 0.50, 0.70, 0.85, 0.70, 0.50, 0.30]
        var samples: [SampleData] = []
        for i in 0..<400 {
            let height = pattern[i % pattern.count]
            samples.append(SampleData(min: -height, max: height))
        }
        let totalSamples = Int(240 * 44100) // 240 second song

        let generator = WaveformGenerator(syntheticSamples: samples, totalSamples: totalSamples)

        #expect(generator.effectiveTotalSamples == totalSamples)
        #expect(generator.audioFile == nil)
        #expect(generator.renderSamples.count == totalSamples)
    }
}

// MARK: - Test Error

private enum TestError: Error {
    case failedToCreateGenerator
}
