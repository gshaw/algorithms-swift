// Julian days, calendar dates, ΔT, mean sidereal time, and a sky position as azimuth and
// altitude. One self-contained file: copy it into an app as it is.
//
// Held to https://algorithms.gshaw.ca/astronomical-time/ by https://github.com/gshaw/algorithms-swift.
// The calendar follows Meeus, Astronomical Algorithms, chapter 7; sidereal time is the
// IAU 1982 expression (Meeus 12.4); ΔT is USNO's observed and predicted table, embedded
// below, which runs out at the end of its predictions.

import Foundation

public enum AstronomicalTime {
    public enum Failure: Error, Equatable, Sendable {
        case outOfRange
        case invalidInput
    }

    public enum Calendar: String, Sendable {
        case gregorian, julian
    }

    /// A calendar date with an astronomical year: 1 BC is year 0.
    public struct CalendarDate: Equatable, Sendable {
        public var year: Int
        public var month: Int
        public var day: Int
        public var calendar: Calendar

        public init(year: Int, month: Int, day: Int, calendar: Calendar) {
            self.year = year
            self.month = month
            self.day = day
            self.calendar = calendar
        }

        /// YYYY-MM-DD, with a sign before years below 0.
        public var text: String {
            String(format: "%@%04d-%02d-%02d", year < 0 ? "-" : "", abs(year), month, day)
        }
    }

    // MARK: - Julian days

    /// The Julian day of a date and time of day, Julian calendar before 1582-10-15 and
    /// Gregorian from it. The ten days between don't exist.
    public static func julianDay(year: Int, month: Int, day: Int, hour: Int = 0, minute: Int = 0, second: Double = 0) throws(Failure) -> Double {
        guard (1...12).contains(month), (0..<24).contains(hour), (0..<60).contains(minute), second >= 0, second < 60 else {
            throw .invalidInput
        }
        let gregorian = (year, month, day) >= (1582, 10, 15)
        guard gregorian || (year, month, day) <= (1582, 10, 4) else { throw .invalidInput }
        let leap = gregorian ? (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 : year % 4 == 0
        let days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        guard (1...days[month - 1]).contains(day) else { throw .invalidInput }

        var y = Double(year), m = Double(month)
        if month <= 2 {
            y -= 1
            m += 12
        }
        var b = 0.0
        if gregorian {
            let a = (y / 100).rounded(.down)
            b = 2 - a + (a / 4).rounded(.down)
        }
        let fraction = (Double(hour) + Double(minute) / 60 + second / 3600) / 24
        return (365.25 * (y + 4716)).rounded(.down) + (30.6001 * (m + 1)).rounded(.down) + Double(day) + fraction + b - 1524.5
    }

    /// The Julian day of an ISO 8601 instant like 2026-01-01T00:00:00Z or -4712-01-01T12:00:00Z.
    public static func julianDay(instant: String) throws(Failure) -> Double {
        let parts = try parse(instant)
        return try julianDay(year: parts.year, month: parts.month, day: parts.day,
                             hour: parts.hour, minute: parts.minute, second: parts.second)
    }

    /// The calendar date a Julian day falls on. Julian days from 0.
    public static func calendarDate(julianDay jd: Double) throws(Failure) -> CalendarDate {
        guard jd >= 0, jd.isFinite else { throw .outOfRange }
        let z = (jd + 0.5).rounded(.down)
        var a = z
        if z >= 2299161 {
            let alpha = ((z - 1867216.25) / 36524.25).rounded(.down)
            a = z + 1 + alpha - (alpha / 4).rounded(.down)
        }
        let b = a + 1524
        let c = ((b - 122.1) / 365.25).rounded(.down)
        let d = (365.25 * c).rounded(.down)
        let e = ((b - d) / 30.6001).rounded(.down)
        let day = Int(b - d - (30.6001 * e).rounded(.down))
        let month = Int(e < 14 ? e - 1 : e - 13)
        let year = Int(month > 2 ? c - 4716 : c - 4715)
        return CalendarDate(year: year, month: month, day: day,
                            calendar: (year, month, day) >= (1582, 10, 15) ? .gregorian : .julian)
    }

    // MARK: - ΔT

    /// TT minus UT1 in seconds, interpolated in USNO's table: observed from 1973-02-01,
    /// then predicted to 2033-10-01. Outside that, `outOfRange`.
    public static func deltaT(decimalYear: Double) throws(Failure) -> Double {
        guard let first = deltaTTable.first, let last = deltaTTable.last,
              decimalYear >= first.year, decimalYear <= last.year else { throw .outOfRange }
        var i = 1
        while deltaTTable[i].year < decimalYear { i += 1 }
        let (y0, v0) = deltaTTable[i - 1], (y1, v1) = deltaTTable[i]
        return v0 + (v1 - v0) * (decimalYear - y0) / (y1 - y0)
    }

    // MARK: - Sidereal time and the sky

    /// Greenwich and local mean sidereal time in hours, 0 to 24, for a Julian day in UT1.
    public static func siderealTime(julianDay jd: Double, longitude: Double) -> (greenwich: Double, local: Double) {
        let t = (jd - 2451545) / 36525
        let degrees = 280.46061837 + 360.98564736629 * (jd - 2451545) + 0.000387933 * t * t - t * t * t / 38710000
        let greenwich = wrapped(degrees, 360) / 15
        return (greenwich, wrapped(greenwich + longitude / 15, 24))
    }

    /// Azimuth, clockwise from north, and geometric altitude of a sky position, from a
    /// place at a Julian day in UT1. The hour angle is local mean sidereal time minus
    /// right ascension.
    public static func horizontal(rightAscension: Double, declination: Double, latitude: Double, longitude: Double,
                                  julianDay jd: Double) throws(Failure) -> (azimuth: Double, altitude: Double) {
        guard (-90...90).contains(latitude), (-180...180).contains(longitude), (-90...90).contains(declination) else {
            throw .outOfRange
        }
        let local = siderealTime(julianDay: jd, longitude: longitude).local
        let h = radians((local - rightAscension) * 15), delta = radians(declination), phi = radians(latitude)
        let x = -cos(h) * cos(delta) * sin(phi) + sin(delta) * cos(phi)
        let y = -sin(h) * cos(delta)
        let z = cos(h) * cos(delta) * cos(phi) + sin(delta) * sin(phi)
        return (wrapped(degrees(atan2(y, x)), 360), degrees(atan2(z, (x * x + y * y).squareRoot())))
    }

    // MARK: - Helpers

    private static func radians(_ degrees: Double) -> Double { degrees * .pi / 180 }
    private static func degrees(_ radians: Double) -> Double { radians * 180 / .pi }

    private static func wrapped(_ value: Double, _ period: Double) -> Double {
        let r = value.truncatingRemainder(dividingBy: period)
        return r < 0 ? r + period : r
    }

    private static func parse(_ instant: String) throws(Failure) -> (year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Double) {
        var text = Substring(instant)
        var sign = 1
        if text.first == "-" {
            sign = -1
            text = text.dropFirst()
        }
        guard text.last == "Z" else { throw .invalidInput }
        let halves = text.dropLast().split(separator: "T")
        guard halves.count == 2 else { throw .invalidInput }
        let date = halves[0].split(separator: "-"), clock = halves[1].split(separator: ":")
        guard date.count == 3, clock.count == 3, date[0].count >= 4,
              let year = Int(date[0]), let month = Int(date[1]), let day = Int(date[2]),
              let hour = Int(clock[0]), let minute = Int(clock[1]), let second = Double(clock[2]) else { throw .invalidInput }
        return (sign * year, month, day, hour, minute, second)
    }

    /// USNO's ΔT in seconds by decimal year: deltat.data every January, its first and
    /// last months, then deltat.preds after the last observation.
    private static let deltaTTable: [(year: Double, seconds: Double)] = [
        (1973.084932, 43.4724),
        (1974.000000, 44.4841),
        (1975.000000, 45.4761),
        (1976.000000, 46.4567),
        (1977.000000, 47.5214),
        (1978.000000, 48.5344),
        (1979.000000, 49.5861),
        (1980.000000, 50.5387),
        (1981.000000, 51.3808),
        (1982.000000, 52.1668),
        (1983.000000, 52.9565),
        (1984.000000, 53.7882),
        (1985.000000, 54.3427),
        (1986.000000, 54.8713),
        (1987.000000, 55.3222),
        (1988.000000, 55.8197),
        (1989.000000, 56.3000),
        (1990.000000, 56.8553),
        (1991.000000, 57.5653),
        (1992.000000, 58.3092),
        (1993.000000, 59.1218),
        (1994.000000, 59.9845),
        (1995.000000, 60.7853),
        (1996.000000, 61.6287),
        (1997.000000, 62.2950),
        (1998.000000, 62.9659),
        (1999.000000, 63.4673),
        (2000.000000, 63.8285),
        (2001.000000, 64.0908),
        (2002.000000, 64.2998),
        (2003.000000, 64.4734),
        (2004.000000, 64.5736),
        (2005.000000, 64.6876),
        (2006.000000, 64.8452),
        (2007.000000, 65.1464),
        (2008.000000, 65.4573),
        (2009.000000, 65.7768),
        (2010.000000, 66.0699),
        (2011.000000, 66.3246),
        (2012.000000, 66.6030),
        (2013.000000, 66.9069),
        (2014.000000, 67.2810),
        (2015.000000, 67.6439),
        (2016.000000, 68.1024),
        (2017.000000, 68.5927),
        (2018.000000, 68.9676),
        (2019.000000, 69.2202),
        (2020.000000, 69.3612),
        (2021.000000, 69.3594),
        (2022.000000, 69.2945),
        (2023.000000, 69.2039),
        (2024.000000, 69.1752),
        (2025.000000, 69.1377),
        (2026.000000, 69.1099),
        (2026.246575, 69.1330),
        (2026.249315, 69.09),
        (2026.498630, 69.11),
        (2026.747945, 69.09),
        (2027.000000, 69.14),
        (2027.249315, 69.21),
        (2027.498630, 69.26),
        (2027.750685, 69.26),
        (2028.000000, 69.34),
        (2028.248634, 69.44),
        (2028.500000, 69.51),
        (2028.748634, 69.54),
        (2028.997268, 69.63),
        (2029.249315, 69.75),
        (2029.498630, 69.83),
        (2029.747945, 69.87),
        (2030.000000, 69.97),
        (2030.249315, 70.08),
        (2030.498630, 70.17),
        (2030.747945, 70.21),
        (2031.000000, 70.32),
        (2031.249315, 70.42),
        (2031.498630, 70.51),
        (2031.750685, 70.53),
        (2032.000000, 70.62),
        (2032.248634, 70.72),
        (2032.500000, 70.82),
        (2032.748634, 70.86),
        (2032.997268, 70.98),
        (2033.249315, 71.10),
        (2033.498630, 71.20),
        (2033.747945, 71.25),
    ]
}
