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
            let snap = renderer.snapshot
            let (scale, offset) = waveformCorrection(snapshot: snap, viewWidth: width)

            Renderer(
                waveformData: snap.sampleData,
                displayMode: renderer.displayMode,
                xScale: scale,
                xOffset: offset
            )
            .clipped()
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

    /// Computes x scale and offset to map renderer pixels to current viewport screen coords.
    /// Uses the same formula as grid lines: (sample - vp.lower) / vp.count * width.
    /// This ensures waveform and grid positions use identical floating-point operations.
    private func waveformCorrection(snapshot: RenderSnapshot, viewWidth: CGFloat) -> (scale: CGFloat, offset: CGFloat) {
        guard snapshot.sampleData.count > 0, viewport.visibleCount > 0 else {
            return (1, 0)
        }
        let scale = CGFloat(snapshot.samplesPerPixel) * viewWidth / CGFloat(viewport.visibleCount)
        let offset = viewport.screenX(for: snapshot.paddedTimelineStart, viewWidth: viewWidth)
        return (scale, offset)
    }
}
