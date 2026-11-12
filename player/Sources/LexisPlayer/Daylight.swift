import Foundation

/// How much daylight a room is likely to hold, from the sun's height where
/// the Apple TV is: it has no light sensor, and the viewer is not asked to
/// say whether it is day. The place is the time zone's own city, out of the
/// tz database's zone.tab, close enough for the sun's height to a degree.
public enum Daylight {
    /// 0 until the sun is up, 1 once it is 20 degrees up, smooth between:
    /// through a window, a sun on the horizon lights a room less than its
    /// lamps, and the room fills over the first hours after sunrise and
    /// empties the same way before sunset.
    public static func share(at date: Date, in zone: TimeZone = .current) -> Float {
        let place = coordinates[zone.identifier]
            // a zone the table lacks: its standard offset's meridian, at a mid latitude
            ?? (latitude: 45, longitude: Double(zone.secondsFromGMT(for: date) - Int(zone.daylightSavingTimeOffset(for: date))) / 240)
        // NOAA's low precision sun: within a degree, which is all this needs
        let days = date.timeIntervalSince1970 / 86400 - 10957.5
        let anomaly = (357.529 + 0.98560028 * days) * .pi / 180
        let longitude = (280.459 + 0.98564736 * days) * .pi / 180
            + (1.915 * sin(anomaly) + 0.020 * sin(2 * anomaly)) * .pi / 180
        let obliquity = (23.439 - 0.00000036 * days) * .pi / 180
        let declination = asin(sin(obliquity) * sin(longitude))
        let rightAscension = atan2(cos(obliquity) * sin(longitude), cos(longitude))
        let sidereal = (280.46061837 + 360.98564736629 * days) * .pi / 180
        let hourAngle = sidereal + place.longitude * .pi / 180 - rightAscension
        let latitude = place.latitude * .pi / 180
        let height = asin(sin(latitude) * sin(declination) + cos(latitude) * cos(declination) * cos(hourAngle))
            * 180 / .pi
        let t = Float(min(max(height / 20, 0), 1))
        return t * t * (3 - 2 * t)
    }

    private static let coordinates: [String: (latitude: Double, longitude: Double)] = {
        guard let url = Bundle.module.url(forResource: "zones", withExtension: "txt"),
            let text = try? String(contentsOf: url, encoding: .utf8)
        else { return [:] }
        var table: [String: (latitude: Double, longitude: Double)] = [:]
        for line in text.split(separator: "\n") {
            let fields = line.split(separator: " ")
            guard fields.count == 3, let latitude = Double(fields[1]), let longitude = Double(fields[2]) else { continue }
            table[String(fields[0])] = (latitude, longitude)
        }
        return table
    }()
}
