import SwiftUI

struct CustomDurationPickerSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var hours: Int = 0
    @State private var minutes: Int = 5
    @State private var seconds: Int = 0
    @State private var errorMessage: String?

    var initialDuration: TimeInterval
    var onSelect: (TimeInterval) -> Void

    init(initialDuration: TimeInterval, onSelect: @escaping (TimeInterval) -> Void) {
        self.initialDuration = initialDuration
        self.onSelect = onSelect

        let totalSeconds = Int(initialDuration)
        let h = totalSeconds / 3600
        let m = (totalSeconds % 3600) / 60
        let s = totalSeconds % 60

        _hours = State(initialValue: min(12, h))
        _minutes = State(initialValue: m)
        _seconds = State(initialValue: s)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Text("Выберите длительность")
                    .font(.headline)
                    .padding(.top, 16)

                HStack(spacing: 0) {
                    // Hours
                    VStack {
                        Text("Часы")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Picker("Часы", selection: $hours) {
                            ForEach(0...12, id: \.self) { h in
                                Text("\(h)").tag(h)
                            }
                        }
                        .pickerStyle(.wheel)
                    }

                    // Minutes
                    VStack {
                        Text("Минуты")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Picker("Минуты", selection: $minutes) {
                            ForEach(0...59, id: \.self) { m in
                                Text("\(m)").tag(m)
                            }
                        }
                        .pickerStyle(.wheel)
                    }

                    // Seconds
                    VStack {
                        Text("Секунды")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Picker("Секунды", selection: $seconds) {
                            ForEach(0...59, id: \.self) { s in
                                Text("\(s)").tag(s)
                            }
                        }
                        .pickerStyle(.wheel)
                    }
                }
                .frame(height: 180)
                .padding(.horizontal)

                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(LocusTheme.danger)
                        .padding(.horizontal)
                }

                Spacer()

                Button {
                    let totalSec = TimeInterval(hours * 3600 + minutes * 60 + seconds)
                    if totalSec < 5 {
                        errorMessage = "Минимальное время — 5 секунд"
                        return
                    }
                    if totalSec > 43200 {
                        errorMessage = "Максимальное время — 12 часов"
                        return
                    }

                    onSelect(totalSec)
                    dismiss()
                } label: {
                    Text("Установить длительность")
                        .font(.headline)
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Capsule().fill(LocusTheme.accent))
                        .padding(.horizontal, 24)
                }
                .buttonStyle(.plain)
                .padding(.bottom, 24)
            }
            .navigationTitle("Своё время")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
            }
        }
    }
}
