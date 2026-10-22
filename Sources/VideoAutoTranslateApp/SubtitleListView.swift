import SwiftUI
import VideoAutoTranslateCore

public struct SubtitleListView: View {
    @ObservedObject var appState: AppState
    @State private var lastClickedIndex: Int? = nil
    @State private var searchText: String = ""

    public var body: some View {
        VStack(spacing: 0) {
            // 工具栏头部 (靠右排列：撤销、重做、合并)
            ScrollView(.horizontal) {
                subtitleToolbar
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .scrollIndicators(.visible)
            .frame(height: 44)
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
                        Text(!appState.project.subtitles.isEmpty
                             ? "没有匹配的字幕，请修改搜索词或清除搜索"
                             : (appState.project.videoURL == nil ? "请先打开或拖拽视频文件" : "尚未提取字幕，点击上方「语音转录」开始"))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 6) {
                            ForEach(Array(filteredSubtitles.enumerated()), id: \.element.id) { index, item in
                                // A filtered next row can hide the actual source neighbor.
                                let canMergeNext = searchText.isEmpty && (index + 1 < filteredSubtitles.count)
                                let isRowSelected = (appState.project.selectedSubtitleID == item.id) || appState.selectedSubtitleIDs.contains(item.id)

                                SubtitleRowView(
                                    item: item,
                                    isSelected: isRowSelected,
                                    isPlaying: appState.project.playingSubtitleID == item.id,
                                    rowIndex: appState.project.subtitles.firstIndex(where: { $0.id == item.id }) ?? index,
                                    isMultiSelected: appState.selectedSubtitleIDs.contains(item.id),
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
                                        appState.splitSubtitle(id: item.id, atCharIndex: cursorIndex)
                                    },
                                    onToggleSelect: {
                                        if appState.selectedSubtitleIDs.contains(item.id) {
                                            appState.selectedSubtitleIDs.remove(item.id)
                                        } else {
                                            appState.selectedSubtitleIDs.insert(item.id)
                                        }
                                        appState.project.selectedSubtitleID = item.id
                                        lastClickedIndex = index
                                    },
                                    onMergeNext: {
                                        appState.mergeSubtitleWithNext(id: item.id)
                                        appState.selectedSubtitleIDs.removeAll()
                                    },
                                    onDelete: {
                                        appState.deleteSubtitle(id: item.id)
                                        appState.selectedSubtitleIDs.remove(item.id)
                                    },
                                    onFocus: {
                                        appState.project.selectedSubtitleID = item.id
                                        lastClickedIndex = index
                                    }
                                )
                                .id(item.id)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    appState.project.selectedSubtitleID = item.id
                                    if NSEvent.modifierFlags.contains(.shift), let lastIdx = lastClickedIndex {
                                        let lower = min(lastIdx, index)
                                        let upper = max(lastIdx, index)
                                        for i in lower...upper {
                                            if i < filteredSubtitles.count {
                                                appState.selectedSubtitleIDs.insert(filteredSubtitles[i].id)
                                            }
                                        }
                                    } else if NSEvent.modifierFlags.contains(.command) {
                                        if appState.selectedSubtitleIDs.contains(item.id) {
                                            appState.selectedSubtitleIDs.remove(item.id)
                                        } else {
                                            appState.selectedSubtitleIDs.insert(item.id)
                                        }
                                        lastClickedIndex = index
                                    } else {
                                        appState.selectedSubtitleIDs = [item.id]
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
        .onChange(of: searchText) { _, _ in
            appState.selectedSubtitleIDs.removeAll()
            lastClickedIndex = nil
        }
    }

    private var subtitleToolbar: some View {
        HStack(spacing: 8) {
            Text(searchText.isEmpty
                 ? "字幕列表 (\(filteredSubtitles.count))"
                 : "字幕列表 (\(filteredSubtitles.count)/\(appState.project.subtitles.count))")
                .font(.headline)

            Spacer()

            // 1. 撤销按钮 (Cmd+Z)
            Button(action: {
                appState.undo()
            }) {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.uturn.backward")
                    Text("撤销")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!appState.canUndo)
            .keyboardShortcut("z", modifiers: .command)
            .help("撤销上一步编辑操作 (Cmd+Z)")

            // 2. 重做按钮 (Cmd+Shift+Z)
            Button(action: {
                appState.redo()
            }) {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.uturn.forward")
                    Text("重做")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!appState.canRedo)
            .keyboardShortcut("z", modifiers: [.command, .shift])
            .help("恢复上一步被撤销的操作 (Cmd+Shift+Z)")

            // 3. 智能分句按钮 (基于每个单词的毫秒时间戳与 LLM 语义规整)
            Button(action: {
                Task {
                    await appState.runSmartSegmentation()
                }
            }) {
                HStack(spacing: 3) {
                    Image(systemName: "sparkles")
                    Text("智能分句")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(appState.project.subtitles.isEmpty || appState.project.isProcessing)
            .help("调用大模型结合每个词的精确时间戳进行语义智能断句规整")

            // 4. 匹配译文时间轴按钮 (跟译文的时间轴做匹配：保持原文与译文对应不变，按译文自然语速重排时间轴)
            let hasTranslations = appState.project.subtitles.contains { !$0.translatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            Button(action: {
                Task {
                    await appState.matchTimelineToTranslation()
                }
            }) {
                HStack(spacing: 3) {
                    Image(systemName: "waveform.badge.clock")
                    Text("匹配译文时间轴")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!hasTranslations || appState.project.isProcessing)
            .help("实测配音时长，按局部语境分组；固定每组开头和结尾，组内自动平衡语速。预览并试听后应用")

            // 5. 合并按钮 (仅当选中多个且连续时可用，平时置灰禁用)
            let canMergeMulti = appState.canMergeMultipleConsecutive(ids: appState.selectedSubtitleIDs)
            let mergeButtonTitle: String = {
                if appState.selectedSubtitleIDs.count >= 2 {
                    return "合并 (\(appState.selectedSubtitleIDs.count))"
                } else {
                    return "合并"
                }
            }()

            Button(action: {
                appState.mergeSubtitles(ids: appState.selectedSubtitleIDs)
                appState.selectedSubtitleIDs.removeAll()
            }) {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.triangle.merge")
                    Text(mergeButtonTitle)
                }
            }
            .buttonStyle(.bordered)
            .tint(canMergeMulti ? .accentColor : nil)
            .controlSize(.small)
            .disabled(!canMergeMulti)
            .keyboardShortcut("j", modifiers: .command)
            .help(canMergeMulti ? "合并当前选中的 \(appState.selectedSubtitleIDs.count) 行连续字幕 (Cmd+J)" : (appState.selectedSubtitleIDs.count >= 2 ? "选中的字幕行必须连续方可合并" : "勾选多个且连续的字幕行即可激活合并功能"))
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
