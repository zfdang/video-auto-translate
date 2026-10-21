import SwiftUI
import VideoAutoTranslateCore

public struct SubtitleListView: View {
    @ObservedObject var appState: AppState
    @State private var selectedIDs: Set<UUID> = []
    @State private var searchText: String = ""

    public var body: some View {
        VStack(spacing: 0) {
            // 工具栏头部 (靠右排列：撤销、重做、合并)
            HStack(spacing: 8) {
                Text("字幕列表 (\(filteredSubtitles.count))")
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

                // 4. 合并按钮 (需选中 2 行或多行相邻字幕，支持 Cmd+J)
                let canMergeNow = appState.canMerge(ids: selectedIDs)
                Button(action: {
                    appState.mergeSubtitles(ids: selectedIDs)
                    selectedIDs.removeAll()
                }) {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.triangle.merge")
                        Text(selectedIDs.count >= 2 ? "合并 (\(selectedIDs.count))" : "合并")
                    }
                }
                .buttonStyle(.bordered)
                .tint(canMergeNow ? .accentColor : nil)
                .controlSize(.small)
                .disabled(!canMergeNow)
                .keyboardShortcut("j", modifiers: .command)
                .help(canMergeNow ? "合并当前选中的 \(selectedIDs.count) 行相邻字幕 (Cmd+J)" : "请先按住 Shift 键选中相邻的多行字幕，再点击合并 (Cmd+J)")
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
                        Text(appState.project.videoURL == nil ? "请先打开或拖拽视频文件" : "尚未提取字幕，点击上方「语音转录」开始")
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
                                    isPlaying: appState.project.playingSubtitleID == item.id,
                                    onSeek: {
                                        appState.seek(to: item.startTime)
                                        appState.project.selectedSubtitleID = item.id
                                    },
                                    onAudition: { target in
                                        Task {
                                            await appState.auditionSubtitle(item, target: target)
                                        }
                                    },
                                    onSplit: { cursorIndex in
                                        appState.splitSubtitle(id: item.id, atCharIndex: cursorIndex)
                                    }
                                )
                                .id(item.id)
                                .onTapGesture {
                                    appState.project.selectedSubtitleID = item.id
                                    if NSEvent.modifierFlags.contains(.shift) || NSEvent.modifierFlags.contains(.command) {
                                        if selectedIDs.contains(item.id) {
                                            selectedIDs.remove(item.id)
                                        } else {
                                            selectedIDs.insert(item.id)
                                        }
                                    } else {
                                        // 普通单击选中单行；若已有多选状态则重置为当前单行
                                        if selectedIDs.count > 1 {
                                            selectedIDs = [item.id]
                                        } else {
                                            selectedIDs = [item.id]
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
