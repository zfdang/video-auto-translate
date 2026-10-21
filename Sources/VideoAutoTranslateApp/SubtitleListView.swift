import SwiftUI
import VideoAutoTranslateCore

public struct SubtitleListView: View {
    @ObservedObject var appState: AppState
    @State private var selectedIDs: Set<UUID> = []
    @State private var lastClickedIndex: Int? = nil
    @State private var showTiming = false
    @State private var searchText: String = ""

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("字幕 \(filteredSubtitles.count)/\(appState.project.subtitles.count)").font(.headline).lineLimit(1)
                Spacer(minLength: 0)
                Button { showTiming.toggle() } label: { Image(systemName: "waveform.path") }
                    .accessibilityLabel("调时与波形").help("调时与波形").disabled(appState.project.selectedSubtitleID == nil)
                Button { appState.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                    .accessibilityLabel("撤销").help("撤销").disabled(!appState.canUndo || appState.project.isProcessing)
                Button { appState.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                    .accessibilityLabel("重做").help("重做").disabled(!appState.canRedo || appState.project.isProcessing)
                Menu("编辑") {
                    Button("智能分句（翻译前）") { Task { await appState.runSmartSegmentation() } }
                        .disabled(appState.project.subtitles.isEmpty || appState.project.subtitles.contains { !$0.translatedText.isEmpty })
                    Button("匹配译文时间轴…") { Task { await appState.matchTimelineToTranslation() } }
                        .disabled(!appState.project.subtitles.contains { !$0.translatedText.isEmpty })
                    Button("合并所选连续行") { appState.mergeSubtitles(ids: selectedIDs); selectedIDs.removeAll() }
                        .disabled(!appState.canMergeMultipleConsecutive(ids: selectedIDs))
                }.disabled(appState.project.isProcessing)
            }.buttonStyle(.bordered).controlSize(.small).padding(8)

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

            if showTiming, let item = appState.project.subtitles.first(where: { $0.id == appState.project.selectedSubtitleID }) {
                TimingInspector(appState: appState, item: item)
                Divider()
            }
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
                        if !appState.project.subtitles.isEmpty {
                            Text("没有匹配的字幕，原有内容仍保留")
                            Button("清除筛选") { searchText = "" }
                        } else {
                            Text(appState.project.videoURL == nil ? "请先打开或拖拽视频文件" : "尚未提取字幕，点击上方「语音转录」开始")
                                .foregroundColor(.secondary)
                        }
                    }
                    Spacer()
                }
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 6) {
                            ForEach(Array(filteredSubtitles.enumerated()), id: \.element.id) { index, item in
                                let projectIndex = appState.project.subtitles.firstIndex(where: { $0.id == item.id }) ?? index
                                let canMergeNext = searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && projectIndex + 1 < appState.project.subtitles.count
                                let isRowSelected = (appState.project.selectedSubtitleID == item.id) || selectedIDs.contains(item.id)

                                SubtitleRowView(
                                    item: item,
                                    isSelected: isRowSelected,
                                    isPlaying: appState.project.playingSubtitleID == item.id,
                                    rowIndex: projectIndex,
                                    isMultiSelected: selectedIDs.contains(item.id),
                                    canMergeWithNext: canMergeNext,
                                    onSeek: {
                                        appState.seek(to: item.startTime)
                                        appState.project.selectedSubtitleID = item.id
                                        lastClickedIndex = index
                                    },
                                    onAudition: { target in
                                        Task {
                                            await appState.auditionSubtitle(item, target: target)
                                        }
                                    },
                                    onSplit: { cursorIndex in
                                        appState.requestSplit(id: item.id, atCharIndex: cursorIndex)
                                    },
                                    onToggleSelect: {
                                        if selectedIDs.contains(item.id) {
                                            selectedIDs.remove(item.id)
                                        } else {
                                            selectedIDs.insert(item.id)
                                        }
                                        appState.project.selectedSubtitleID = item.id
                                        lastClickedIndex = index
                                    },
                                    onMergeNext: {
                                        appState.mergeSubtitleWithNext(id: item.id)
                                        selectedIDs.removeAll()
                                    },
                                    onDelete: {
                                        appState.deleteSubtitle(id: item.id)
                                        selectedIDs.remove(item.id)
                                    },
                                    onFocus: {
                                        appState.project.selectedSubtitleID = item.id
                                        lastClickedIndex = index
                                    }
                                )
                                .disabled(appState.project.isProcessing)
                                .id(item.id)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    appState.project.selectedSubtitleID = item.id
                                    if NSEvent.modifierFlags.contains(.shift), let lastIdx = lastClickedIndex {
                                        let lower = min(lastIdx, index)
                                        let upper = max(lastIdx, index)
                                        for i in lower...upper {
                                            if i < filteredSubtitles.count {
                                                selectedIDs.insert(filteredSubtitles[i].id)
                                            }
                                        }
                                    } else if NSEvent.modifierFlags.contains(.command) {
                                        if selectedIDs.contains(item.id) {
                                            selectedIDs.remove(item.id)
                                        } else {
                                            selectedIDs.insert(item.id)
                                        }
                                        lastClickedIndex = index
                                    } else {
                                        selectedIDs = [item.id]
                                        lastClickedIndex = index
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
        .onChange(of: appState.project.subtitles.map(\.id)) { _, ids in
            selectedIDs.formIntersection(Set(ids))
            lastClickedIndex = nil
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
