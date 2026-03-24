import SwiftUI

struct Highlight: Shape {
    let selectedSamples: SampleRange

    @EnvironmentObject var generator: WaveformGenerator

    func path(in rect: CGRect) -> Path {
        Path { path in
            guard selectedSamples.count > 0, selectedSamples.overlaps(generator.renderSamples) else { return }

            let sampleCount = generator.sampleData.count
            guard sampleCount > 0 else { return }

            let startPosition = max(0, generator.position(of: selectedSamples.lowerBound))
            let endPosition = min(generator.position(of: selectedSamples.upperBound), generator.width)

            let startIndex = max(0, min(Int(startPosition), sampleCount - 1))
            let endIndex = max(startIndex, min(Int(endPosition), sampleCount))

            path.move(to: CGPoint(x: startPosition, y: rect.midY))

            for index in startIndex..<endIndex {
                let x = CGFloat(index)
                let max = rect.midY + (rect.midY * CGFloat(generator.sampleData[index].max))
                path.addLine(to: CGPoint(x: x, y: max))
            }

            for index in (startIndex..<endIndex).reversed() {
                let x = CGFloat(index)
                let min = rect.midY + (rect.midY * CGFloat(generator.sampleData[index].min))
                path.addLine(to: CGPoint(x: x, y: min))
            }

            path.closeSubpath()
        }
    }
}
