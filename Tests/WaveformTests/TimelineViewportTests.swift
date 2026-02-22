import Testing
@testable import Waveform

@Suite("TimelineViewport Tests")
struct TimelineViewportTests {

    // MARK: - Init

    @Test("Full-range init covers entire timeline")
    func fullRangeInit() {
        let vp = TimelineViewport(totalLength: 10000)
        #expect(vp.visibleRange == 0..<10000)
        #expect(vp.totalLength == 10000)
    }

    // MARK: - Normalized

    @Test("normalizedStart/End for full range")
    func normalizedFullRange() {
        let vp = TimelineViewport(totalLength: 10000)
        #expect(vp.normalizedStart == 0)
        #expect(vp.normalizedEnd == 1)
    }

    @Test("normalizedStart/End for partial range")
    func normalizedPartialRange() {
        let vp = TimelineViewport(visibleRange: 2500..<7500, totalLength: 10000)
        #expect(vp.normalizedStart == 0.25)
        #expect(vp.normalizedEnd == 0.75)
    }

    @Test("normalized handles zero totalLength")
    func normalizedZeroLength() {
        let vp = TimelineViewport(totalLength: 0)
        #expect(vp.normalizedStart == 0)
        #expect(vp.normalizedEnd == 1)
    }

    // MARK: - Edge detection

    @Test("edge detection at boundaries")
    func edgeDetection() {
        let full = TimelineViewport(totalLength: 10000)
        #expect(full.isAtLeadingEdge)
        #expect(full.isAtTrailingEdge)

        let middle = TimelineViewport(visibleRange: 1000..<5000, totalLength: 10000)
        #expect(!middle.isAtLeadingEdge)
        #expect(!middle.isAtTrailingEdge)

        let atStart = TimelineViewport(visibleRange: 0..<5000, totalLength: 10000)
        #expect(atStart.isAtLeadingEdge)
        #expect(!atStart.isAtTrailingEdge)

        let atEnd = TimelineViewport(visibleRange: 5000..<10000, totalLength: 10000)
        #expect(!atEnd.isAtLeadingEdge)
        #expect(atEnd.isAtTrailingEdge)
    }

    // MARK: - Zoom

    @Test("zoom in reduces visible count")
    func zoomIn() {
        let vp = TimelineViewport(totalLength: 10000)
        let zoomed = vp.zoomed(by: 2.0) // 2x zoom in
        #expect(zoomed.visibleCount < vp.visibleCount)
        #expect(zoomed.visibleCount == 5000)
    }

    @Test("zoom out increases visible count")
    func zoomOut() {
        let vp = TimelineViewport(visibleRange: 2500..<7500, totalLength: 10000)
        let zoomed = vp.zoomed(by: 0.5) // zoom out
        #expect(zoomed.visibleCount > vp.visibleCount)
    }

    @Test("zoom clamps to bounds")
    func zoomClamping() {
        let vp = TimelineViewport(visibleRange: 0..<1000, totalLength: 10000)
        let zoomed = vp.zoomed(by: 0.01) // extreme zoom out
        #expect(zoomed.visibleRange.lowerBound >= 0)
        #expect(zoomed.visibleRange.upperBound <= 10000)
    }

    @Test("zoom respects minVisibleCount floor")
    func zoomMinVisibleCount() {
        let vp = TimelineViewport(visibleRange: 4000..<6000, totalLength: 10000)
        let zoomed = vp.zoomed(by: 100, minVisibleCount: 800) // extreme zoom in
        #expect(zoomed.visibleCount >= 800)
    }

    @Test("zoom without minVisibleCount can go to 1")
    func zoomNoFloor() {
        let vp = TimelineViewport(visibleRange: 4999..<5001, totalLength: 10000)
        let zoomed = vp.zoomed(by: 100) // extreme zoom in, no floor
        #expect(zoomed.visibleCount >= 1)
    }

    @Test("zoom preserves center")
    func zoomPreservesCenter() {
        let vp = TimelineViewport(visibleRange: 4000..<6000, totalLength: 10000)
        let center = 5000
        let zoomed = vp.zoomed(by: 2.0)
        let zoomedCenter = zoomed.visibleRange.lowerBound + zoomed.visibleCount / 2
        // Center should be approximately preserved (within rounding)
        #expect(abs(zoomedCenter - center) <= 1)
    }

    // MARK: - Pan

    @Test("pan by positive delta moves right")
    func panRight() {
        let vp = TimelineViewport(visibleRange: 0..<5000, totalLength: 10000)
        let panned = vp.panned(by: 100, viewWidth: 500) // 100pt right on 500pt wide view
        #expect(panned.visibleRange.lowerBound > 0)
        #expect(panned.visibleCount == vp.visibleCount)
    }

    @Test("pan clamps at leading edge")
    func panClampLeading() {
        let vp = TimelineViewport(visibleRange: 100..<5100, totalLength: 10000)
        let panned = vp.panned(by: -10000, viewWidth: 500) // extreme left
        #expect(panned.visibleRange.lowerBound == 0)
        #expect(panned.visibleCount == vp.visibleCount)
    }

    @Test("pan clamps at trailing edge")
    func panClampTrailing() {
        let vp = TimelineViewport(visibleRange: 5000..<9900, totalLength: 10000)
        let panned = vp.panned(by: 10000, viewWidth: 500) // extreme right
        #expect(panned.visibleRange.upperBound == 10000)
        #expect(panned.visibleCount == vp.visibleCount)
    }

    @Test("pan preserves visible count")
    func panPreservesCount() {
        let vp = TimelineViewport(visibleRange: 2000..<7000, totalLength: 10000)
        let panned = vp.panned(by: 50, viewWidth: 400)
        #expect(panned.visibleCount == vp.visibleCount)
    }

    @Test("pannedBySamples works directly")
    func pannedBySamples() {
        let vp = TimelineViewport(visibleRange: 0..<5000, totalLength: 10000)
        let panned = vp.pannedBySamples(1000)
        #expect(panned.visibleRange == 1000..<6000)
    }

    // MARK: - Coordinate Conversion

    @Test("screenX for sample at start of visible range")
    func screenXAtStart() {
        let vp = TimelineViewport(visibleRange: 1000..<6000, totalLength: 10000)
        let x = vp.screenX(for: 1000, viewWidth: 500)
        #expect(x == 0)
    }

    @Test("screenX for sample at end of visible range")
    func screenXAtEnd() {
        let vp = TimelineViewport(visibleRange: 1000..<6000, totalLength: 10000)
        let x = vp.screenX(for: 6000, viewWidth: 500)
        #expect(x == 500)
    }

    @Test("screenX for sample at midpoint")
    func screenXAtMid() {
        let vp = TimelineViewport(visibleRange: 0..<10000, totalLength: 10000)
        let x = vp.screenX(for: 5000, viewWidth: 400)
        #expect(x == 200)
    }

    @Test("screenX for sample before visible range is negative")
    func screenXBeforeRange() {
        let vp = TimelineViewport(visibleRange: 5000..<10000, totalLength: 10000)
        let x = vp.screenX(for: 0, viewWidth: 500)
        #expect(x < 0)
    }

    @Test("timelineSample roundtrips with screenX")
    func coordinateRoundtrip() {
        let vp = TimelineViewport(visibleRange: 2000..<8000, totalLength: 10000)
        let viewWidth: CGFloat = 600
        let originalSample = 5000

        let x = vp.screenX(for: originalSample, viewWidth: viewWidth)
        let recovered = vp.timelineSample(for: x, viewWidth: viewWidth)

        #expect(abs(recovered - originalSample) <= 1)
    }

    @Test("timelineSample clamps to valid range")
    func timelineSampleClamping() {
        let vp = TimelineViewport(visibleRange: 0..<5000, totalLength: 10000)
        let sample = vp.timelineSample(for: -100, viewWidth: 500)
        #expect(sample >= 0)
        let sample2 = vp.timelineSample(for: 10000, viewWidth: 500)
        #expect(sample2 <= 10000)
    }
}
