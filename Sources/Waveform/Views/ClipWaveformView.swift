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
            Renderer(waveformData: renderer.sampleData, displayMode: renderer.displayMode)
                .onChange(of: viewport) { _, newViewport in
                    renderer.update(viewport: newViewport, clip: clip, width: geometry.size.width)
                }
                .onChange(of: clip) { _, newClip in
                    renderer.update(viewport: viewport, clip: newClip, width: geometry.size.width)
                }
                .onChange(of: geometry.size.width) { _, newWidth in
                    renderer.update(viewport: viewport, clip: clip, width: newWidth)
                }
                .onChange(of: renderer.displayMode) { _, _ in
                    renderer.update(viewport: viewport, clip: clip, width: geometry.size.width)
                }
                .onAppear {
                    renderer.update(viewport: viewport, clip: clip, width: geometry.size.width)
                }
        }
    }
}
