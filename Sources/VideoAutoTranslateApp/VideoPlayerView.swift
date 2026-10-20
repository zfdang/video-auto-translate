import SwiftUI
import AVKit
import CoreMedia
import VideoAutoTranslateCore

/// macOS 原生视频播放器视图（带字幕实时浮层）
public struct VideoPlayerView: View {
    @ObservedObject var appState: AppState

    public var body: some View {
        ZStack(alignment: .bottom) {
            NativeAVPlayerView(player: appState.player)
                .background(Color.black)

            // 实时字幕浮层
            if let activeSubtitle = currentSubtitle {
                VStack(spacing: 4) {
                    if !activeSubtitle.translatedText.isEmpty {
                        Text(activeSubtitle.translatedText)
                            .font(.system(size: 20, weight: .bold))
                            .foregroundColor(.yellow)
                            .shadow(color: .black, radius: 2, x: 1, y: 1)
                    }
                    Text(activeSubtitle.originalText)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.white)
                        .shadow(color: .black, radius: 2, x: 1, y: 1)
                }
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.black.opacity(0.6))
                .cornerRadius(8)
                .padding(.bottom, 24)
                .transition(.opacity)
            }
        }
    }

    private var currentSubtitle: SubtitleItem? {
        let current = appState.currentTime
        return appState.project.subtitles.first(where: {
            current >= $0.startTime && current <= $0.endTime
        })
    }
}

struct NativeAVPlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .inline
        view.showsFullScreenToggleButton = true
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        nsView.player = player
    }
}
