import CoreLocation
import Foundation
import LexisCore
import WeatherKit

/// The sky over the television, for the evening's nudge: the weather where
/// the Apple TV is, and whether the sun sets early today.
///
/// Asked at most once an hour. Every failure - no WeatherKit entitlement,
/// location refused, no network - hands the core an empty context and says
/// nothing: the trio is the same trio without it.
@MainActor
final class AmbientReader: NSObject, CLLocationManagerDelegate {
    static let shared = AmbientReader()

    private let manager = CLLocationManager()
    private var asked: Date?
    private var located: CheckedContinuation<CLLocation?, Never>?

    /// Below this the day is cold, above the other it is hot, whatever the sky.
    private static let coldCelsius = 5.0
    private static let hotCelsius = 28.0
    /// A sunset before 18:30 is an evening that starts in the dark.
    private static let darkBefore = 18 * 60 + 30

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyReduced
    }

    func refresh() {
        #if DEBUG
        // LexisShots measures the player alone: a location prompt over the
        // film would take the remote.
        if ProcessInfo.processInfo.arguments.contains("-lexis-play-local") { return }
        #endif
        if let asked, Date().timeIntervalSince(asked) < 3_600 { return }
        asked = Date()
        Task { @MainActor in
            let ambient = await read()
            CoreClient.calls.async { CoreClient.shared.setAmbient(ambient: ambient) }
        }
    }

    private func read() async -> Ambient? {
        guard let location = await locate(),
            let sky = try? await WeatherService.shared.weather(
                for: location, including: .current, .daily)
        else { return nil }
        let (now, days) = sky
        let celsius = now.temperature.converted(to: .celsius).value
        let weather: WeatherKind =
            switch now.condition {
            case .rain, .heavyRain, .drizzle, .freezingRain, .freezingDrizzle, .sunShowers,
                .isolatedThunderstorms, .scatteredThunderstorms, .strongStorms, .thunderstorms,
                .tropicalStorm, .hurricane:
                .rain
            case .snow, .heavySnow, .flurries, .sleet, .blizzard, .blowingSnow, .sunFlurries,
                .wintryMix:
                .snow
            case .frigid: .cold
            case .hot: .hot
            case _ where celsius < Self.coldCelsius: .cold
            case _ where celsius > Self.hotCelsius: .hot
            case .clear, .mostlyClear: .clear
            default: .other
            }
        let sunset = days.first?.sun.sunset.map {
            Calendar.current.component(.hour, from: $0) * 60
                + Calendar.current.component(.minute, from: $0)
        }
        return Ambient(weather: weather, darkEarly: sunset.map { $0 < Self.darkBefore } ?? false)
    }

    /// Where the television is, roughly, or nil when it may not be asked.
    private func locate() async -> CLLocation? {
        switch manager.authorizationStatus {
        case .denied, .restricted: return nil
        case .notDetermined: manager.requestWhenInUseAuthorization()
        default: manager.requestLocation()
        }
        return await withCheckedContinuation { continuation in
            located?.resume(returning: nil)
            located = continuation
        }
    }

    private func answer(_ location: CLLocation?) {
        located?.resume(returning: location)
        located = nil
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            switch manager.authorizationStatus {
            case .authorizedWhenInUse, .authorizedAlways: manager.requestLocation()
            case .notDetermined: break
            default: answer(nil)
            }
        }
    }

    nonisolated func locationManager(
        _ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]
    ) {
        let last = locations.last
        Task { @MainActor in answer(last) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in answer(nil) }
    }
}
