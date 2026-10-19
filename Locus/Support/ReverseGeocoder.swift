import CoreLocation
import Foundation

@MainActor
final class ReverseGeocoder: ObservableObject {
    @Published var placeName: String?
    @Published var isGeocoding = false

    private let geocoder = CLGeocoder()
    private var lastCoordinate: CLLocationCoordinate2D?

    init() {}

    func reverseGeocode(_ coordinate: CLLocationCoordinate2D?) {
        guard let coordinate else {
            placeName = nil
            lastCoordinate = nil
            return
        }

        if let last = lastCoordinate,
           abs(last.latitude - coordinate.latitude) < 0.0001,
           abs(last.longitude - coordinate.longitude) < 0.0001 {
            return
        }

        lastCoordinate = coordinate
        isGeocoding = true

        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        geocoder.reverseGeocodeLocation(location) { [weak self] placemarks, error in
            Task { @MainActor in
                guard let self else { return }
                self.isGeocoding = false
                guard let placemark = placemarks?.first, error == nil else {
                    self.placeName = nil
                    return
                }

                var parts: [String] = []
                if let name = placemark.name {
                    parts.append(name)
                }
                if let locality = placemark.locality, locality != placemark.name {
                    parts.append(locality)
                }
                if let country = placemark.country, !parts.contains(country) {
                    parts.append(country)
                }

                self.placeName = parts.isEmpty ? nil : parts.joined(separator: ", ")
            }
        }
    }
}
