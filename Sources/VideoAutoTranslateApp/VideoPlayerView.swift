import SwiftUI
import AVKit
import CoreMedia
import VideoAutoTranslateCore

/// macOS 原生视频播放器视图（带字幕实时浮层与音频预览切换）
public struct VideoPlayerView: View {
    @ObservedObject var appState: AppState

    public var body: some View {
        ZStack {
            NativeAVPlayerView(player: appState.player)
                .background(Color.black)

            // 顶部右上角音轨切换浮层 (仅在已加载视频时展示)
            if appState.project.videoURL != nil {
                VStack {
                    HStack {
                        Spacer()
                        audioTrackSelector
                    }
                    .padding(12)
                    Spacer()
                }
            }

            // 底部实时字幕浮层
            if let activeSubtitle = currentSubtitle {
                VStack {
                    Spacer()
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
                }
                .transition(.opacity)
            }
        }
    }

    // MARK: - 音频预览切换器

    private var audioTrackSelector: some View {
        HStack(spacing: 3) {
            Image(systemName: iconForTrack(appState.previewAudioTrack))
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(appState.previewAudioTrack == .original ? .white.opacity(0.85) : .accentColor)
                .padding(.leading, 7)
                .padding(.trailing, 2)

            ForEach(PreviewAudioTrack.allCases) { track in
                let isSelected = appState.previewAudioTrack == track
                let isAvailable = (track == .original) || appState.hasDubbing

                Button {
                    Task {
                        await appState.setPreviewAudioTrack(track)
                    }
                } label: {
                    Text(track.rawValue)
                        .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                        .foregroundColor(
                            isSelected ? .white :
                            (isAvailable ? .white.opacity(0.85) : .white.opacity(0.4))
                        )
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            isSelected ? Color.accentColor : Color.clear,
                            in: RoundedRectangle(cornerRadius: 5)
                        )
                }
                .buttonStyle(.plain)
                .help(
                    isAvailable
                        ? "视频预览播放：\(track.rawValue)"
                        : "尚未生成配音，请先在工具栏点击「4 自动配音」"
                )
            }
        }
        .padding(3)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.white.opacity(0.2), lineWidth: 0.5)
        )
        .shadow(color: Color.black.opacity(0.35), radius: 4, x: 0, y: 2)
    }

    private func iconForTrack(_ track: PreviewAudioTrack) -> String {
        switch track {
        case .original:
            return "speaker.wave.2.fill"
        case .translated:
            return "waveform"
        case .overlay:
            return "square.2.layers.3d"
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
