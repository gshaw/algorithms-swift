// Distance and bearing on a sphere, the three norths, and bearings written as degrees,
// mils and compass points. One self-contained file: copy it into an app as it is.
//
// Held to https://algorithms.gshaw.ca/bearings/ by https://github.com/gshaw/algorithms-swift.
// The sphere is Turf's, radius 6,371,008.8 m, so distances match the map. Mils and the
// G-M angle follow FM 3-25.26; compass point names are Bowditch's (Pub. 9, Appendix B).

import Foundation

public enum Bearings {
    public enum Failure: Error, Equatable, Sendable {
        case outOfRange
        case invalidInput
    }

    public enum North: String, Sendable {
        case `true`, magnetic, grid
    }

    public enum AngleUnit: String, Sendable {
        case degrees, mils
    }

    public enum Direction: String, Sendable {
        case left, right, none
    }

    // MARK: - On the sphere

    /// The great-circle distance in metres and the initial bearing, 0 to 360, between two points.
    public static func inverse(fromLatitude lat1: Double, fromLongitude lon1: Double,
                               toLatitude lat2: Double, toLongitude lon2: Double) throws(Failure) -> (distance: Double, bearing: Double) {
        guard valid(lat1, lon1), valid(lat2, lon2) else { throw .outOfRange }
        let phi1 = radians(lat1), phi2 = radians(lat2), dLambda = radians(lon2 - lon1)
        let y = cos(phi2) * sin(dLambda)
        let x = cos(phi1) * sin(phi2) - sin(phi1) * cos(phi2) * cos(dLambda)
        // Vincenty's form of the central angle, accurate from 0 to antipodes.
        let sigma = atan2((y * y + x * x).squareRoot(), sin(phi1) * sin(phi2) + cos(phi1) * cos(phi2) * cos(dLambda))
        return (earthRadius * sigma, wrapped(degrees(atan2(y, x))))
    }

    /// The point `distance` metres from a start along an initial bearing.
    public static func destination(fromLatitude lat: Double, fromLongitude lon: Double,
                                   distance: Double, bearing: Double) throws(Failure) -> (latitude: Double, longitude: Double) {
        guard valid(lat, lon), distance >= 0, distance.isFinite, bearing.isFinite else { throw .outOfRange }
        let phi1 = radians(lat), theta = radians(bearing), delta = distance / earthRadius
        let z = sin(phi1) * cos(delta) + cos(phi1) * sin(delta) * cos(theta)
        let across = sin(theta) * sin(delta)
        let along = cos(phi1) * cos(delta) - sin(phi1) * sin(delta) * cos(theta)
        let phi2 = atan2(z, (along * along + across * across).squareRoot())
        let lambda = atan2(across * cos(phi1), cos(delta) - sin(phi1) * z)
        var longitude = (lon + degrees(lambda)).truncatingRemainder(dividingBy: 360)
        if longitude >= 180 { longitude -= 360 } else if longitude < -180 { longitude += 360 }
        return (degrees(phi2), longitude)
    }

    // MARK: - Bearings

    /// The reverse of a bearing, 0 to 360.
    public static func backAzimuth(_ bearing: Double) -> Double {
        wrapped(bearing + 180)
    }

    /// The smaller turn from one bearing to another. Exactly 180° is right.
    public static func turn(from: Double, to: Double) -> (degrees: Double, direction: Direction) {
        let difference = wrapped(to - from)
        if difference == 0 { return (0, .none) }
        return difference <= 180 ? (difference, .right) : (360 - difference, .left)
    }

    /// A bearing converted between norths. Declination is true to magnetic and convergence
    /// true to grid, both east positive: true = magnetic + declination = grid + convergence.
    public static func convert(_ bearing: Double, from: North, to: North,
                               declination: Double, convergence: Double) -> Double {
        func offset(_ north: North) -> Double {
            switch north {
            case .true: 0
            case .magnetic: declination
            case .grid: convergence
            }
        }
        return wrapped(bearing + offset(from) - offset(to))
    }

    /// A bearing as text: whole degrees as `045°`, or mils at 6400 to the circle as
    /// `0800`. Rounds half up, then wraps, so 359.6° is `000°`.
    public static func format(_ bearing: Double, unit: AngleUnit) -> String {
        switch unit {
        case .degrees:
            let whole = Int(wrapped(bearing).rounded(.toNearestOrAwayFromZero)) % 360
            return String(format: "%03d°", whole)
        case .mils:
            let whole = Int((wrapped(bearing) * 6400 / 360).rounded(.toNearestOrAwayFromZero)) % 6400
            return String(format: "%04d", whole)
        }
    }

    /// The nearest of 4, 8, 16 or 32 compass points, as Bowditch abbreviates it. Half-way
    /// between two points goes clockwise.
    public static func compassPoint(_ bearing: Double, points count: Int) throws(Failure) -> String {
        guard [4, 8, 16, 32].contains(count) else { throw .invalidInput }
        let index = Int((wrapped(bearing) / (360 / Double(count)) + 0.5).rounded(.down)) % count
        return compassPoints[index * (32 / count)]
    }

    // MARK: - Helpers

    /// Turf's mean radius in metres.
    private static let earthRadius = 6_371_008.8

    private static let compassPoints = [
        "N", "N by E", "NNE", "NE by N", "NE", "NE by E", "ENE", "E by N",
        "E", "E by S", "ESE", "SE by E", "SE", "SE by S", "SSE", "S by E",
        "S", "S by W", "SSW", "SW by S", "SW", "SW by W", "WSW", "W by S",
        "W", "W by N", "WNW", "NW by W", "NW", "NW by N", "NNW", "N by W",
    ]

    private static func valid(_ latitude: Double, _ longitude: Double) -> Bool {
        (-90...90).contains(latitude) && (-180...180).contains(longitude)
    }

    private static func radians(_ degrees: Double) -> Double { degrees * .pi / 180 }
    private static func degrees(_ radians: Double) -> Double { radians * 180 / .pi }

    /// Into 0 to 360.
    private static func wrapped(_ degrees: Double) -> Double {
        let value = degrees.truncatingRemainder(dividingBy: 360)
        return value < 0 ? value + 360 : value + 0
    }
}
