import AVFoundation
import Accelerate
import os

class GenerateTask {
    let audioBuffer: AVAudioPCMBuffer
    let samplesToPrepend: Int
    let samplesToAppend: Int
    private let isCancelled = OSAllocatedUnfairLock(initialState: false)

    init(
        audioBuffer: AVAudioPCMBuffer,
        samplesToPrepend: Int = 0,
        samplesToAppend: Int = 0
    ) {
        self.audioBuffer = audioBuffer
        self.samplesToPrepend = samplesToPrepend
        self.samplesToAppend = samplesToAppend
    }

    func cancel() {
        isCancelled.withLock { $0 = true }
    }

    // MARK: - New path: direct audio range (used by ClipRenderer)

    /// Generates waveform data for a direct audio file sample range.
    /// No virtual padding — the caller handles clip positioning.
    func resume(
        width: CGFloat,
        audioRange: Range<Int>,
        displayMode: WaveformDisplayMode = .normal,
        completion: @escaping ([SampleData]) -> Void
    ) {
        let pixelCount = Int(width)
        var sampleData = [SampleData](repeating: .zero, count: pixelCount)

        DispatchQueue.global(qos: .userInteractive).async {
            let channels = Int(self.audioBuffer.format.channelCount)
            let samplesPerPoint = audioRange.count / pixelCount

            guard let floatChannelData = self.audioBuffer.floatChannelData else {
                completion(sampleData)
                return
            }
            guard samplesPerPoint > 0 else {
                completion(sampleData)
                return
            }

            sampleData.withUnsafeMutableBufferPointer { buffer in
                DispatchQueue.concurrentPerform(iterations: pixelCount) { point in
                    guard !self.isCancelled.withLock({ $0 }) else { return }

                    let start = audioRange.lowerBound + (point * samplesPerPoint)
                    let length = samplesPerPoint

                    guard start >= 0, start + length <= Int(self.audioBuffer.frameLength) else { return }

                    var data: SampleData = .zero
                    for channel in 0..<channels {
                        let pointer = floatChannelData[channel].advanced(by: start)
                        let stride = vDSP_Stride(self.audioBuffer.stride)
                        let len = vDSP_Length(length)

                        var value: Float = 0
                        vDSP_minv(pointer, stride, &value, len)
                        data.min = min(value, data.min)

                        vDSP_maxv(pointer, stride, &value, len)
                        data.max = max(value, data.max)
                    }
                    buffer[point] = data
                }
            }

            if displayMode == .transientHighlight {
                TransientDetector.computeWeights(&sampleData)
            }

            guard !self.isCancelled.withLock({ $0 }) else { return }
            completion(sampleData)
        }
    }

    // MARK: - Legacy path: virtual padding (used by WaveformGenerator)

    func resume(
        width: CGFloat,
        renderSamples: SampleRange,
        displayMode: WaveformDisplayMode = .normal,
        completion: @escaping ([SampleData]) -> Void
    ) {
        var sampleData = [SampleData](repeating: .zero, count: Int(width))

        DispatchQueue.global(qos: .userInteractive).async {
            let channels = Int(self.audioBuffer.format.channelCount)
            let actualSampleCount = Int(self.audioBuffer.frameLength)
            let samplesPerPoint = renderSamples.count / Int(width)

            guard let floatChannelData = self.audioBuffer.floatChannelData else { return }
            guard samplesPerPoint > 0 else { return }

            sampleData.withUnsafeMutableBufferPointer { buffer in
                DispatchQueue.concurrentPerform(iterations: Int(width)) { point in
                    guard !self.isCancelled.withLock({ $0 }) else { return }

                    let pointStartVirtual = renderSamples.lowerBound + (point * samplesPerPoint)
                    let pointEndVirtual = pointStartVirtual + samplesPerPoint

                    let fullyInPrepend = pointEndVirtual <= self.samplesToPrepend
                    let fullyInAppend = pointStartVirtual >= (self.samplesToPrepend + actualSampleCount)

                    if fullyInPrepend || fullyInAppend {
                        return
                    }

                    let actualStart = max(pointStartVirtual, self.samplesToPrepend) - self.samplesToPrepend
                    let actualEnd = min(pointEndVirtual, self.samplesToPrepend + actualSampleCount) - self.samplesToPrepend
                    let actualLength = actualEnd - actualStart

                    guard actualLength > 0 else { return }

                    var data: SampleData = .zero
                    for channel in 0..<channels {
                        let pointer = floatChannelData[channel].advanced(by: actualStart)
                        let stride = vDSP_Stride(self.audioBuffer.stride)
                        let length = vDSP_Length(actualLength)

                        var value: Float = 0

                        vDSP_minv(pointer, stride, &value, length)
                        data.min = min(value, data.min)

                        vDSP_maxv(pointer, stride, &value, length)
                        data.max = max(value, data.max)
                    }
                    buffer[point] = data
                }
            }

            if displayMode == .transientHighlight {
                TransientDetector.computeWeights(&sampleData)
            }

            DispatchQueue.main.async {
                guard !self.isCancelled.withLock({ $0 }) else { return }
                completion(sampleData)
            }
        }
    }

}
