import CoreLocation
import SwiftUI

struct ManualCoordinateSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var latText: String = ""
    @State private var lonText: String = ""
    @State private var validationError: String?

    var onSelect: (CLLocationCoordinate2D) -> Void

    init(initialCoordinate: CLLocationCoordinate2D? = nil, onSelect: @escaping (CLLocationCoordinate2D) -> Void) {
        self.onSelect = onSelect
        if let initial = initialCoordinate {
            _latText = State(initialValue: String(format: "%.6f", initial.latitude))
            _lonText = State(initialValue: String(format: "%.6f", initial.longitude))
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("Координаты / Coordinates")) {
                    HStack {
                        Text("Широта (Lat):")
                            .font(.subheadline)
                        TextField("-90.0 ... 90.0", text: $latText)
                            .keyboardType(.numbersAndPunctuation)
                            .autocorrectionDisabled()
                    }

                    HStack {
                        Text("Долгота (Lon):")
                            .font(.subheadline)
                        TextField("-180.0 ... 180.0", text: $lonText)
                            .keyboardType(.numbersAndPunctuation)
                            .autocorrectionDisabled()
                    }

                    Button {
                        pasteFromClipboard()
                    } label: {
                        HStack {
                            Image(systemName: "doc.on.clipboard")
                            Text("Вставить из буфера обмена")
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(LocusTheme.accent)
                    }
                }

                if let validationError {
                    Section {
                        Text(validationError)
                            .font(.footnote)
                            .foregroundStyle(LocusTheme.danger)
                    }
                }

                Section {
                    Button {
                        applyCoordinates()
                    } label: {
                        Text("Применить координаты")
                            .font(.headline)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .foregroundStyle(LocusTheme.accent)
                    }
                }
            }
            .navigationTitle("Ввод координат")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
            }
        }
    }

    private func applyCoordinates() {
        let cleanLat = latText.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanLon = lonText.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespacesAndNewlines)

        guard let lat = Double(cleanLat), let lon = Double(cleanLon) else {
            validationError = "Введите корректные числа для широты и долготы"
            return
        }

        guard lat >= -90.0 && lat <= 90.0 else {
            validationError = "Широта должна быть в диапазоне от -90 до 90"
            return
        }

        guard lon >= -180.0 && lon <= 180.0 else {
            validationError = "Долгота должна быть в диапазоне от -180 до 180"
            return
        }

        validationError = nil
        let coord = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        onSelect(coord)
        dismiss()
    }

    private func pasteFromClipboard() {
        guard let text = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            validationError = "Буфер обмена пуст"
            return
        }

        // Try parsing various coordinate formats:
        // 1. "55.7558, 37.6173" or "55.7558; 37.6173" or "55.7558 37.6173"
        // 2. Maps URL: containing @55.7558,37.6173 or q=55.7558,37.6173 or ll=55.7558,37.6173
        if let match = parseCoordinates(from: text) {
            latText = String(format: "%.6f", match.latitude)
            lonText = String(format: "%.6f", match.longitude)
            validationError = nil
        } else {
            validationError = "Не удалось распознать координаты в буфере обмена"
        }
    }

    private func parseCoordinates(from text: String) -> CLLocationCoordinate2D? {
        let pattern = #"([-+]?[0-9]*\.?[0-9]+)[,\s;]+([-+]?[0-9]*\.?[0-9]+)"#
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let nsString = text as NSString
            let results = regex.matches(in: text, range: NSRange(location: 0, length: nsString.length))
            if let first = results.first, first.numberOfRanges >= 3 {
                let latStr = nsString.substring(with: first.range(at: 1))
                let lonStr = nsString.substring(with: first.range(at: 2))
                if let lat = Double(latStr), let lon = Double(lonStr),
                   lat >= -90 && lat <= 90, lon >= -180 && lon <= 180 {
                    return CLLocationCoordinate2D(latitude: lat, longitude: lon)
                }
            }
        }
        return nil
    }
}
