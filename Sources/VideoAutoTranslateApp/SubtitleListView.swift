import SwiftUI
import VideoAutoTranslateCore

public struct SubtitleListView: View {
    @ObservedObject var appState: AppState
    @State private var selectedIDs: Set<UUID> = []
    @State private var searchText: String = ""

    public var body: some View {
        VStack(spacing: 0) {
            // 工具栏头部
            HStack {
                Text("字幕列表 (\(filteredSubtitles.count))")
                    .font(.headline)

                Spacer()

                if selectedIDs.count >= 2 {
                    Button(action: {
                        appState.mergeSubtitles(ids: selectedIDs)
                        selectedIDs.removeAll()
                    }) {
                        Label("合并选中 (\(selectedIDs.count))", systemImage: "arrow.triangle.merge")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            // 搜索过滤栏
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("搜索字幕原文或译文...", text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(6)
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(6)
            .padding(8)

            // 滚动字幕列表
            if filteredSubtitles.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    if appState.project.isProcessing {
                        ProgressView(value: appState.project.progress)
                            .progressViewStyle(.linear)
                            .frame(maxWidth: 220)
                        Text(appState.project.currentStepName)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    } else {
                        Image(systemName: "text.bubble")
                            .font(.system(size: 40))
                            .foregroundColor(.secondary)
                        Text(appState.project.videoURL == nil ? "请先打开或拖拽视频文件" : "尚未提取字幕，点击上方「一键转录」开始")
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 6) {
                            ForEach(filteredSubtitles) { item in
                                SubtitleRowView(
                                    item: item,
                                    isSelected: appState.project.selectedSubtitleID == item.id || selectedIDs.contains(item.id),
                                    onSeek: {
                                        appState.seek(to: item.startTime)
                                        appState.project.selectedSubtitleID = item.id
                                    },
                                    onAudition: {
                                        Task {
                                            await appState.auditionSubtitle(item)
                                        }
                                    },
                                    onSplit: {
                                        // 默认从中间字数拆分
                                        let mid = max(1, item.originalText.count / 2)
                                        appState.splitCurrentSubtitle(atCharIndex: mid)
                                    }
                                )
                                .id(item.id)
                                .onTapGesture {
                                    appState.project.selectedSubtitleID = item.id
                                    if NSEvent.modifierFlags.contains(.shift) {
                                        if selectedIDs.contains(item.id) {
                                            selectedIDs.remove(item.id)
                                        } else {
                                            selectedIDs.insert(item.id)
                                        }
                                    }
                                }
                            }
                        }
                        .padding(8)
                    }
                    .onChange(of: appState.project.selectedSubtitleID) { _, newID in
                        if let id = newID {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                proxy.scrollTo(id, anchor: .center)
                            }
                        }
                    }
                }
            }
        }
    }

    private var filteredSubtitles: [SubtitleItem] {
        if searchText.trimmingCharacters(in: .whitespaces).isEmpty {
            return appState.project.subtitles
        }
        return appState.project.subtitles.filter {
            $0.originalText.localizedCaseInsensitiveContains(searchText) ||
            $0.translatedText.localizedCaseInsensitiveContains(searchText)
        }
    }
}
