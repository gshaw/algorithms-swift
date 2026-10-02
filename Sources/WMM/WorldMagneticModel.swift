// The World Magnetic Model 2025 (WMM2025), from NOAA NCEI and the British Geological
// Survey. One self-contained file: copy it into an app as it is.
//
// Held to https://algorithms.gshaw.ca/wmm/ by https://github.com/gshaw/algorithms-swift.
// The method is the WMM2025 technical report's, https://doi.org/10.25923/prbc-s316, and
// the coefficients are NOAA's WMM.COF, verbatim. Public domain, like the model.

import Foundation

public enum WorldMagneticModel {
    /// The model's first and last instants, as decimal years.
    public static let validFrom = 2025.0
    public static let validUntil = 2030.0

    public enum Blackout: String, Sendable {
        /// The compass is fine.
        case none
        /// Horizontal intensity under 6000 nT: compass accuracy may be degraded.
        case caution
        /// Horizontal intensity under 2000 nT: the compass is unreliable.
        case unreliable
    }

    public enum Failure: Error, Equatable, Sendable {
        case outOfRange
        case invalidInput
    }

    public struct Field: Equatable, Sendable {
        /// Degrees from true north to magnetic north, east positive.
        public var declination: Double
        /// Degrees below the horizontal, down positive.
        public var inclination: Double
        /// Components in nanoteslas: X, Y, Z, H and F.
        public var north: Double
        public var east: Double
        public var down: Double
        public var horizontal: Double
        public var total: Double
        /// Degrees from polar stereographic grid north to magnetic north; nil between 55° S and 55° N.
        public var gridVariation: Double?
        public var blackout: Blackout

        public init(declination: Double, inclination: Double, north: Double, east: Double, down: Double,
                    horizontal: Double, total: Double, gridVariation: Double? = nil, blackout: Blackout = .none) {
            self.declination = declination
            self.inclination = inclination
            self.north = north
            self.east = east
            self.down = down
            self.horizontal = horizontal
            self.total = total
            self.gridVariation = gridVariation
            self.blackout = blackout
        }
    }

    /// The field at a place and time. Latitude −90 to 90 and longitude −180 to 360, in
    /// degrees on WGS84; height −1 to 850 km above the ellipsoid; a decimal year from
    /// 2025.0 to 2030.0.
    public static func field(latitude: Double, longitude: Double, heightInKilometers height: Double = 0, decimalYear: Double) throws(Failure) -> Field {
        guard (-90...90).contains(latitude), (-180...360).contains(longitude), (-1...850).contains(height),
              (validFrom...validUntil).contains(decimalYear) else { throw .outOfRange }

        // Geodetic to geocentric spherical, on WGS84 (report equations 17 and 18).
        let a = 6378.137, flattening = 1 / 298.257223563
        let e2 = flattening * (2 - flattening)
        let phi = latitude * .pi / 180, lambda = longitude * .pi / 180
        let rc = a / (1 - e2 * sin(phi) * sin(phi)).squareRoot()
        let p = (rc + height) * cos(phi)
        let z = (rc * (1 - e2) + height) * sin(phi)
        let r = (p * p + z * z).squareRoot()
        let phiPrime = asin(z / r)

        let n = coefficients.degree
        let dt = decimalYear - validFrom
        let (legendre, derivative) = schmidtLegendre(sinPhi: sin(phiPrime), degree: n)

        var bx = 0.0, by = 0.0, bz = 0.0
        for degree in 1...n {
            let ratio = pow(6371.2 / r, Double(degree + 2))
            for order in 0...degree {
                let i = index(degree, order)
                let g = coefficients.g[i] + dt * coefficients.gDot[i]
                let h = coefficients.h[i] + dt * coefficients.hDot[i]
                let cosM = cos(Double(order) * lambda), sinM = sin(Double(order) * lambda)
                bz -= ratio * (g * cosM + h * sinM) * Double(degree + 1) * legendre[i]
                by += ratio * (g * sinM - h * cosM) * Double(order) * legendre[i]
                bx -= ratio * (g * cosM + h * sinM) * derivative[i]
            }
        }
        let cosPhiPrime = cos(phiPrime)
        if abs(cosPhiPrime) > 1e-10 {
            by /= cosPhiPrime
        } else {
            by = eastAtPole(sinPhi: sin(phiPrime), lambda: lambda, r: r, dt: dt)
        }

        // Back from the geocentric frame to the geodetic one.
        let psi = phiPrime - phi
        let x = bx * cos(psi) - bz * sin(psi)
        let down = bx * sin(psi) + bz * cos(psi)
        let horizontal = (x * x + by * by).squareRoot()
        let declination = atan2(by, x) * 180 / .pi

        var gridVariation: Double?
        if latitude >= 55 {
            gridVariation = wrapped(declination - longitude)
        } else if latitude <= -55 {
            gridVariation = wrapped(declination + longitude)
        }

        return Field(
            declination: declination,
            inclination: atan2(down, horizontal) * 180 / .pi,
            north: x,
            east: by,
            down: down,
            horizontal: horizontal,
            total: (horizontal * horizontal + down * down).squareRoot(),
            gridVariation: gridVariation,
            blackout: horizontal < 2000 ? .unreliable : horizontal < 6000 ? .caution : .none
        )
    }

    /// The decimal year for a calendar date: the year plus the days before the date over
    /// the days in its year, so 1 January is a whole year.
    public static func decimalYear(year: Int, month: Int, day: Int) throws(Failure) -> Double {
        let isLeap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
        let days = [31, isLeap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        guard (1...12).contains(month), (1...days[month - 1]).contains(day) else { throw .invalidInput }
        let dayOfYear = days[..<(month - 1)].reduce(0, +) + day
        return Double(year) + Double(dayOfYear - 1) / Double(isLeap ? 366 : 365)
    }

    /// The decimal year for the UTC calendar date of an instant.
    public static func decimalYear(for date: Date) -> Double {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return try! decimalYear(year: parts.year!, month: parts.month!, day: parts.day!)
    }

    // MARK: - The expansion

    private static func index(_ n: Int, _ m: Int) -> Int { n * (n + 1) / 2 + m }

    private static func wrapped(_ degrees: Double) -> Double {
        var value = degrees.truncatingRemainder(dividingBy: 360)
        if value > 180 { value -= 360 } else if value <= -180 { value += 360 }
        return value
    }

    /// Schmidt semi-normalized associated Legendre functions of sin φ′ and their
    /// derivatives with respect to φ′, by NOAA's recursion.
    private static func schmidtLegendre(sinPhi x: Double, degree nMax: Int) -> ([Double], [Double]) {
        let count = index(nMax, nMax) + 1
        var p = [Double](repeating: 0, count: count)
        var dp = [Double](repeating: 0, count: count)
        let z = ((1 - x) * (1 + x)).squareRoot()
        p[0] = 1
        for n in 1...nMax {
            for m in 0...n {
                let i = index(n, m)
                if n == m {
                    let j = index(n - 1, m - 1)
                    p[i] = z * p[j]
                    dp[i] = z * dp[j] + x * p[j]
                } else if n == 1 && m == 0 {
                    let j = index(n - 1, m)
                    p[i] = x * p[j]
                    dp[i] = x * dp[j] - z * p[j]
                } else {
                    let j = index(n - 1, m)
                    if m > n - 2 {
                        p[i] = x * p[j]
                        dp[i] = x * dp[j] - z * p[j]
                    } else {
                        let k = index(n - 2, m)
                        let factor = Double((n - 1) * (n - 1) - m * m) / Double((2 * n - 1) * (2 * n - 3))
                        p[i] = x * p[j] - factor * p[k]
                        dp[i] = x * dp[j] - z * p[j] - factor * dp[k]
                    }
                }
            }
        }
        // Gauss-normalized to Schmidt semi-normalized.
        var schmidt = [Double](repeating: 0, count: count)
        schmidt[0] = 1
        for n in 1...nMax {
            schmidt[index(n, 0)] = schmidt[index(n - 1, 0)] * Double(2 * n - 1) / Double(n)
            for m in 1...n {
                schmidt[index(n, m)] = schmidt[index(n, m - 1)] * (Double((n - m + 1) * (m == 1 ? 2 : 1)) / Double(n + m)).squareRoot()
            }
        }
        for i in 0..<count {
            p[i] *= schmidt[i]
            dp[i] = -dp[i] * schmidt[i]
        }
        return (p, dp)
    }

    /// The east component at a geographic pole, where dividing by cos φ′ fails: the
    /// report's special case, summing only the order-1 terms.
    private static func eastAtPole(sinPhi: Double, lambda: Double, r: Double, dt: Double) -> Double {
        let n = coefficients.degree
        var pole = [Double](repeating: 0, count: n + 1)
        pole[0] = 1
        var schmidt1 = 1.0
        var by = 0.0
        for degree in 1...n {
            let schmidt2 = schmidt1 * Double(2 * degree - 1) / Double(degree)
            let schmidt3 = schmidt2 * (Double(degree * 2) / Double(degree + 1)).squareRoot()
            schmidt1 = schmidt2
            if degree == 1 {
                pole[degree] = pole[degree - 1]
            } else {
                let k = Double((degree - 1) * (degree - 1) - 1) / Double((2 * degree - 1) * (2 * degree - 3))
                pole[degree] = sinPhi * pole[degree - 1] - k * pole[degree - 2]
            }
            let i = index(degree, 1)
            let g = coefficients.g[i] + dt * coefficients.gDot[i]
            let h = coefficients.h[i] + dt * coefficients.hDot[i]
            by += pow(6371.2 / r, Double(degree + 2)) * (g * sin(lambda) - h * cos(lambda)) * pole[degree] * schmidt3
        }
        return by
    }

    // MARK: - Coefficients

    private struct Coefficients {
        var degree = 0
        var g: [Double] = []
        var h: [Double] = []
        var gDot: [Double] = []
        var hDot: [Double] = []
    }

    private static let coefficients: Coefficients = {
        var result = Coefficients()
        let rows = wmmCOF.split(separator: "\n").dropFirst().map { $0.split(separator: " ").compactMap { Double($0) } }
        let degree = rows.map { Int($0[0]) }.max()!
        let count = index(degree, degree) + 1
        result.degree = degree
        result.g = [Double](repeating: 0, count: count)
        result.h = result.g
        result.gDot = result.g
        result.hDot = result.g
        for row in rows {
            let i = index(Int(row[0]), Int(row[1]))
            (result.g[i], result.h[i], result.gDot[i], result.hDot[i]) = (row[2], row[3], row[4], row[5])
        }
        return result
    }()

    /// NOAA's WMM.COF for WMM2025, without its closing lines of 9s: n, m, g, h, ġ and ḣ,
    /// in nT and nT per year.
    private static let wmmCOF = """
        2025.0            WMM-2025     11/13/2024
        1  0  -29351.8       0.0       12.0        0.0
        1  1   -1410.8    4545.4        9.7      -21.5
        2  0   -2556.6       0.0      -11.6        0.0
        2  1    2951.1   -3133.6       -5.2      -27.7
        2  2    1649.3    -815.1       -8.0      -12.1
        3  0    1361.0       0.0       -1.3        0.0
        3  1   -2404.1     -56.6       -4.2        4.0
        3  2    1243.8     237.5        0.4       -0.3
        3  3     453.6    -549.5      -15.6       -4.1
        4  0     895.0       0.0       -1.6        0.0
        4  1     799.5     278.6       -2.4       -1.1
        4  2      55.7    -133.9       -6.0        4.1
        4  3    -281.1     212.0        5.6        1.6
        4  4      12.1    -375.6       -7.0       -4.4
        5  0    -233.2       0.0        0.6        0.0
        5  1     368.9      45.4        1.4       -0.5
        5  2     187.2     220.2        0.0        2.2
        5  3    -138.7    -122.9        0.6        0.4
        5  4    -142.0      43.0        2.2        1.7
        5  5      20.9     106.1        0.9        1.9
        6  0      64.4       0.0       -0.2        0.0
        6  1      63.8     -18.4       -0.4        0.3
        6  2      76.9      16.8        0.9       -1.6
        6  3    -115.7      48.8        1.2       -0.4
        6  4     -40.9     -59.8       -0.9        0.9
        6  5      14.9      10.9        0.3        0.7
        6  6     -60.7      72.7        0.9        0.9
        7  0      79.5       0.0       -0.0        0.0
        7  1     -77.0     -48.9       -0.1        0.6
        7  2      -8.8     -14.4       -0.1        0.5
        7  3      59.3      -1.0        0.5       -0.8
        7  4      15.8      23.4       -0.1        0.0
        7  5       2.5      -7.4       -0.8       -1.0
        7  6     -11.1     -25.1       -0.8        0.6
        7  7      14.2      -2.3        0.8       -0.2
        8  0      23.2       0.0       -0.1        0.0
        8  1      10.8       7.1        0.2       -0.2
        8  2     -17.5     -12.6        0.0        0.5
        8  3       2.0      11.4        0.5       -0.4
        8  4     -21.7      -9.7       -0.1        0.4
        8  5      16.9      12.7        0.3       -0.5
        8  6      15.0       0.7        0.2       -0.6
        8  7     -16.8      -5.2       -0.0        0.3
        8  8       0.9       3.9        0.2        0.2
        9  0       4.6       0.0       -0.0        0.0
        9  1       7.8     -24.8       -0.1       -0.3
        9  2       3.0      12.2        0.1        0.3
        9  3      -0.2       8.3        0.3       -0.3
        9  4      -2.5      -3.3       -0.3        0.3
        9  5     -13.1      -5.2        0.0        0.2
        9  6       2.4       7.2        0.3       -0.1
        9  7       8.6      -0.6       -0.1       -0.2
        9  8      -8.7       0.8        0.1        0.4
        9  9     -12.9      10.0       -0.1        0.1
        10  0      -1.3       0.0        0.1        0.0
        10  1      -6.4       3.3        0.0        0.0
        10  2       0.2       0.0        0.1       -0.0
        10  3       2.0       2.4        0.1       -0.2
        10  4      -1.0       5.3       -0.0        0.1
        10  5      -0.6      -9.1       -0.3       -0.1
        10  6      -0.9       0.4        0.0        0.1
        10  7       1.5      -4.2       -0.1        0.0
        10  8       0.9      -3.8       -0.1       -0.1
        10  9      -2.7       0.9       -0.0        0.2
        10 10      -3.9      -9.1       -0.0       -0.0
        11  0       2.9       0.0        0.0        0.0
        11  1      -1.5       0.0       -0.0       -0.0
        11  2      -2.5       2.9        0.0        0.1
        11  3       2.4      -0.6        0.0       -0.0
        11  4      -0.6       0.2        0.0        0.1
        11  5      -0.1       0.5       -0.1       -0.0
        11  6      -0.6      -0.3        0.0       -0.0
        11  7      -0.1      -1.2       -0.0        0.1
        11  8       1.1      -1.7       -0.1       -0.0
        11  9      -1.0      -2.9       -0.1        0.0
        11 10      -0.2      -1.8       -0.1        0.0
        11 11       2.6      -2.3       -0.1        0.0
        12  0      -2.0       0.0        0.0        0.0
        12  1      -0.2      -1.3        0.0       -0.0
        12  2       0.3       0.7       -0.0        0.0
        12  3       1.2       1.0       -0.0       -0.1
        12  4      -1.3      -1.4       -0.0        0.1
        12  5       0.6      -0.0       -0.0       -0.0
        12  6       0.6       0.6        0.1       -0.0
        12  7       0.5      -0.1       -0.0       -0.0
        12  8      -0.1       0.8        0.0        0.0
        12  9      -0.4       0.1        0.0       -0.0
        12 10      -0.2      -1.0       -0.1       -0.0
        12 11      -1.3       0.1       -0.0        0.0
        12 12      -0.7       0.2       -0.1       -0.1
        """
}
