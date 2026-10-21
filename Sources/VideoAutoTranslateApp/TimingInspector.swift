import SwiftUI
import AVFoundation
import VideoAutoTranslateCore

struct TimingInspector: View {
    @ObservedObject var appState: AppState
    let item: SubtitleItem
    @State private var start: Double = 0
    @State private var end: Double = 0
    @State private var duration: Double = 0
    @State private var peaks: [Float] = []
    @State private var feedback = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("起点")
                TextField("秒", value: $start, format: .number.precision(.fractionLength(3))).frame(width: 80)
                Stepper("", value: $start, in: 0...max(duration, 1), step: 0.01).labelsHidden()
                Text("终点")
                TextField("秒", value: $end, format: .number.precision(.fractionLength(3))).frame(width: 80)
                Stepper("", value: $end, in: 0...max(duration, 1), step: 0.01).labelsHidden()
            }
            GeometryReader { geometry in
                let lower = max(0, item.startTime.secondsValue - 1)
                let upper = min(duration, item.endTime.secondsValue + 1)
                let span = max(0.1, upper - lower)
                ZStack(alignment: .leading) {
                    Canvas { context, size in
                        var path = Path()
                        for (index, peak) in peaks.enumerated() {
                            let time = Double(index) / Double(max(1, peaks.count - 1)) * duration
                            guard time >= lower, time <= upper else { continue }
                            let x = (time - lower) / span * size.width
                            path.move(to: CGPoint(x: x, y: size.height * (0.5 - Double(peak) * 0.45)))
                            path.addLine(to: CGPoint(x: x, y: size.height * (0.5 + Double(peak) * 0.45)))
                        }
                        context.stroke(path, with: .color(.secondary), lineWidth: 1)
                    }
                    boundary(time: $start, color: .blue, lower: lower, span: span, width: geometry.size.width)
                    boundary(time: $end, color: .orange, lower: lower, span: span, width: geometry.size.width)
                }.background(Color.secondary.opacity(0.08)).coordinateSpace(name: "timingWaveform")
            }.frame(height: 48)
            Text("拖动蓝色起点 / 橙色终点只预览；应用后作为一次可撤销修改。步长 10ms。")
                .font(.caption2).foregroundColor(.secondary)
            HStack {
                Button("上一句") { appState.selectAdjacentSubtitle(offset: -1) }
                Button("下一句") { appState.selectAdjacentSubtitle(offset: 1) }
                Button(appState.loopingSubtitleID == item.id ? "停止循环" : "循环此句") { appState.toggleSubtitleLoop(item) }
                Spacer()
                Button("应用时间") {
                    do { try appState.updateTiming(id: item.id, start: start, end: end, duration: duration); feedback = "时间已更新，可撤销" }
                    catch { feedback = error.localizedDescription }
                }.disabled(duration <= 0 || appState.project.isProcessing)
            }.controlSize(.small)
            if !feedback.isEmpty { Text(feedback).font(.caption).foregroundColor(.secondary) }
        }
        .padding(8)
        .onAppear { reset() }
        .onChange(of: item.id) { _, _ in reset() }
        .onChange(of: item.startTime) { _, _ in reset() }
        .onChange(of: item.endTime) { _, _ in reset() }
        .task(id: appState.project.videoURL) {
            guard let url = appState.project.videoURL else { return }
            do {
                let seconds = try await AVURLAsset(url: url).load(.duration).seconds
                let envelope = try await AudioWaveform.load(url: url)
                guard !Task.isCancelled else { return }
                duration = seconds
                peaks = envelope
            } catch { if !Task.isCancelled { feedback = "波形不可用；请确认媒体可读取" } }
        }
    }
    private func reset() { start = item.startTime.secondsValue; end = item.endTime.secondsValue; feedback = "" }
    private func boundary(time: Binding<Double>, color: Color, lower: Double, span: Double, width: Double) -> some View {
        Rectangle().fill(color).frame(width: 8)
            .offset(x: max(0, min(width - 8, (time.wrappedValue - lower) / span * width)))
            .gesture(DragGesture(coordinateSpace: .named("timingWaveform")).onChanged { event in time.wrappedValue = max(0, min(duration, lower + event.location.x / max(1, width) * span)) })
            .accessibilityLabel(color == .blue ? "字幕起点，精确值可在上方输入" : "字幕终点，精确值可在上方输入")
    }
}
