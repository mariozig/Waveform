import SwiftUI

/// Displays a waveform for a single clip positioned within a timeline viewport.
/// No gesture handling — purely a render view.
public struct ClipWaveformView: View {
    @ObservedObject var renderer: ClipRenderer
    let viewport: TimelineViewport
    let clip: ClipDescriptor

    public init(renderer: ClipRenderer, viewport: TimelineViewport, clip: ClipDescriptor) {
        self.renderer = renderer
        self.viewport = viewport
        self.clip = clip
    }

    public var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            Renderer(waveformData: renderer.sampleData, displayMode: renderer.displayMode)
                .offset(x: panCorrectionOffset(viewWidth: width) - renderer.leftPaddingPixels)
                .onChange(of: viewport) { _, newViewport in
                    renderer.update(viewport: newViewport, clip: clip, width: width)
                }
                .onChange(of: clip) { _, newClip in
                    renderer.update(viewport: viewport, clip: newClip, width: width)
                }
                .onChange(of: width) { _, newWidth in
                    renderer.update(viewport: viewport, clip: clip, width: newWidth)
                }
                .onChange(of: renderer.displayMode) { _, _ in
                    renderer.update(viewport: viewport, clip: clip, width: width)
                }
                .onAppear {
                    renderer.update(viewport: viewport, clip: clip, width: width)
                }
        }
    }

    /// Synchronous pixel offset to bridge the gap between the current viewport
    /// and the viewport used to render the current sampleData.
    /// Uses the current viewport's center as reference — stays near zero during
    /// center-zoom (center doesn't move) and gives correct shift during panning.
    private func panCorrectionOffset(viewWidth: CGFloat) -> CGFloat {
        guard let rv = renderer.renderedViewport, rv.visibleCount > 0, viewport.visibleCount > 0 else { return 0 }
        let refSample = (viewport.visibleRange.lowerBound + viewport.visibleRange.upperBound) / 2
        let currentX = viewport.screenX(for: refSample, viewWidth: viewWidth)
        let renderedX = rv.screenX(for: refSample, viewWidth: viewWidth)
        return currentX - renderedX
    }
}
