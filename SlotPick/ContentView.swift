import EventKit
import SlotPickCore
import SlotPickSupport
import SwiftUI

struct ContentView: View {
    @State private var model = SlotPickModel(service: CalendarService(), clipboard: SystemClipboard())
    @Environment(\.scenePhase) private var scenePhase
    private let clock = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("SlotPick").font(.largeTitle.bold())
            Text("カレンダーの空き時間から、面談の候補日時を作成します。")
                .foregroundStyle(.secondary)

            Form {
                Stepper("対象期間：今日から\(model.condition.searchDays)日間", value: $model.condition.searchDays, in: 1...90)
                HStack {
                    Picker("開始", selection: $model.condition.startHour) {
                        ForEach(0..<24) { Text(String(format: "%02d:00", $0)).tag($0) }
                    }
                    Picker("終了", selection: $model.condition.endHour) {
                        ForEach(1...24, id: \.self) { Text(String(format: "%02d:00", $0)).tag($0) }
                    }
                }
                Stepper(
                    "面談時間：\(model.condition.durationMinutes)分", value: $model.condition.durationMinutes, in: 15...240,
                    step: 15)
                Stepper(
                    "予定の前後の余白：\(model.condition.bufferMinutes)分", value: $model.condition.bufferMinutes, in: 0...120,
                    step: 15)
                Stepper("候補数：\(model.condition.candidateCount)件", value: $model.condition.candidateCount, in: 1...20)
                Stepper(
                    "1日最大：\(model.condition.maxCandidatesPerDay)件", value: $model.condition.maxCandidatesPerDay,
                    in: 1...5)
                Toggle("土日を除外", isOn: $model.condition.excludeWeekends)
                Toggle("日本の祝日・休日を除外", isOn: $model.condition.excludeHolidays)
                if model.condition.excludeHolidays {
                    Text("振替休日を含む・\(String(JapaneseHolidays.supportedYears.upperBound))年まで対応")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .disabled(model.isLoading)

            Text("Macに同期された全カレンダーを対象に、終日予定も確認します。「空き時間」の予定は除外します。")
                .font(.caption).foregroundStyle(.secondary)

            HStack {
                Button("候補を生成") { Task { await model.generate() } }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(model.isLoading)
                if model.isLoading { ProgressView().controlSize(.small) }
                Spacer()
                Button(model.copied ? "コピーしました" : "送信用テキストをコピー") { model.copy() }
                    .disabled(model.candidates.isEmpty || model.isLoading)
            }

            if let message = model.message {
                if model.isHolidayDataWarning {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("祝日データがないため、候補を生成できません", systemImage: "exclamationmark.triangle.fill")
                            .font(.headline)
                            .foregroundStyle(.orange)
                        Text(message).textSelection(.enabled)
                        Button("祝日の除外をオフにする") { model.condition.excludeHolidays = false }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(.orange, lineWidth: 1.5))
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("holidayDataWarning")
                } else {
                    Text(message).foregroundStyle(.orange).textSelection(.enabled)
                        .accessibilityIdentifier("statusMessage")
                }
            }
            if model.hasGenerated && model.candidates.count < model.condition.candidateCount {
                Text(
                    model.candidates.isEmpty
                        ? "条件に合う空き時間がありません。期間や時間帯を広げてください。"
                        : "条件に合う候補は\(model.candidates.count)件でした。"
                )
                .foregroundStyle(.secondary)
            }
            ScrollView {
                Text(model.text.isEmpty ? "候補を生成すると、ここに送信用の文章が表示されます。" : model.text)
                    .foregroundStyle(model.text.isEmpty ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("candidateText")
            }
            .padding()
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        }
        .padding(24)
        .frame(minWidth: 580, minHeight: 680)
        .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged)) { _ in
            model.calendarDidChange()
        }
        .onReceive(clock) { _ in model.checkFreshness() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.checkFreshness() }
        }
    }
}
