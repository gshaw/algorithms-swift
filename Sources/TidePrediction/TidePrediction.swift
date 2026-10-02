// The tide at a station from its harmonic constants: the height at any instant, and the
// next high and low. One self-contained file: copy it into an app as it is.
//
// Held to https://algorithms.gshaw.ca/tides/ by https://github.com/gshaw/algorithms-swift.
// The method is Schureman, Manual of Harmonic Analysis and Prediction of Tides (SP 98,
// 1958 reprint), the way NOAA runs it: h = Σ f·H·cos(a·t + (V₀+u) − κ′) over NOAA's 37
// constituents, with one set of V₀+u and f per UTC year. V₀ is for 00:00 UTC on 1 January,
// u and f for the middle of the year, and t is hours since 1 January. The constituent
// definitions match XTide's congen.

import Foundation

public enum TidePrediction {
    public enum Failure: Error, Equatable, Sendable {
        case outOfRange
        case invalidInput
    }

    /// One harmonic constant, as NOAA publishes it.
    public struct Constituent: Equatable, Sendable {
        /// NOAA's name: one of `names`, like `M2`, `LAM2` or `RHO`.
        public var name: String
        /// Mean amplitude H, 0 or more. Its unit is the height's.
        public var amplitude: Double
        /// Greenwich phase lag κ′ in degrees, 0 to 360: NOAA's `phase_GMT`.
        public var phase: Double

        public init(name: String, amplitude: Double, phase: Double) {
            self.name = name
            self.amplitude = amplitude
            self.phase = phase
        }
    }

    public struct Extreme: Equatable, Sendable {
        public var date: Date
        public var height: Double

        public init(date: Date, height: Double) {
            self.date = date
            self.height = height
        }
    }

    public struct Extremes: Equatable, Sendable {
        /// The first local maximum after the start.
        public var high: Extreme
        /// The first local minimum after the start. It may come before the high.
        public var low: Extreme

        public init(high: Extreme, low: Extreme) {
            self.high = high
            self.low = low
        }
    }

    /// NOAA's 37 constituents, in NOAA's order.
    public static let names: [String] = recipes.map(\.name)

    /// The earliest and latest years predicted, the span of XTide's congen tables.
    public static let years = 1700...2100

    // MARK: - Station

    /// A station's constants, checked once. Use this to predict many heights.
    public struct Station: Sendable {
        private let terms: [(index: Int, amplitude: Double, phase: Double)]

        /// Throws `invalidInput` for a name not in `names`, and `outOfRange` for a negative
        /// amplitude or a phase outside 0 to 360.
        public init(constituents: [Constituent]) throws(Failure) {
            var terms: [(Int, Double, Double)] = []
            for c in constituents {
                guard let index = TidePrediction.index[c.name] else { throw .invalidInput }
                guard c.amplitude.isFinite, c.amplitude >= 0, (0...360).contains(c.phase) else { throw .outOfRange }
                if c.amplitude > 0 { terms.append((index, c.amplitude, radians(c.phase))) }
            }
            self.terms = terms
        }

        /// The height above the constants' mean, mean sea level for NOAA's, in the
        /// amplitudes' unit. Throws `outOfRange` outside `years`.
        public func height(at date: Date) throws(Failure) -> Double {
            let (year, hours) = try yearAndHours(date)
            return height(year, hours)
        }

        /// Heights from `start`, `count` of them `interval` seconds apart.
        public func heights(from start: Date, count: Int, interval: TimeInterval) throws(Failure) -> [Double] {
            var out: [Double] = []
            out.reserveCapacity(max(count, 0))
            for i in 0..<max(count, 0) {
                let (year, hours) = try yearAndHours(start.addingTimeInterval(Double(i) * interval))
                out.append(height(year, hours))
            }
            return out
        }

        /// The first high and the first low after `start`, each to well under a second.
        /// Throws `invalidInput` when the curve is flat, and `outOfRange` outside `years`.
        public func nextExtremes(after start: Date) throws(Failure) -> Extremes {
            guard terms.contains(where: { speeds[$0.index] > 0 }) else { throw .invalidInput }
            // The slope's sign, sampled every 5 minutes; a sign change brackets a turn.
            // One period of SA, the slowest constituent, holds both a high and a low.
            let step = 300.0, limit = 2 * 366 * 86400.0
            var high: Extreme?, low: Extreme?
            var t0 = 0.0, s0 = try slope(start)
            while high == nil || low == nil {
                guard t0 < limit else { throw .invalidInput }
                let t1 = t0 + step, s1 = try slope(start.addingTimeInterval(t1))
                let rising = s0 > 0 && s1 <= 0, falling = s0 < 0 && s1 >= 0
                if (rising && high == nil) || (falling && low == nil) {
                    var lo = t0, hi = t1
                    for _ in 0..<20 {
                        let mid = (lo + hi) / 2
                        if try (slope(start.addingTimeInterval(mid)) > 0) == rising { lo = mid } else { hi = mid }
                    }
                    let date = start.addingTimeInterval((lo + hi) / 2)
                    let extreme = Extreme(date: date, height: try height(at: date))
                    if rising { high = extreme } else { low = extreme }
                }
                t0 = t1
                s0 = s1
            }
            return Extremes(high: high!, low: low!)
        }

        private func height(_ year: YearTerms, _ hours: Double) -> Double {
            var sum = 0.0
            for term in terms {
                let i = term.index
                sum += year.f[i] * term.amplitude * cos(speeds[i] * hours + year.vu[i] - term.phase)
            }
            return sum
        }

        /// dh/dt, per hour, in the amplitudes' unit.
        private func slope(_ date: Date) throws(Failure) -> Double {
            let (year, hours) = try yearAndHours(date)
            var sum = 0.0
            for term in terms {
                let i = term.index
                sum -= speeds[i] * year.f[i] * term.amplitude * sin(speeds[i] * hours + year.vu[i] - term.phase)
            }
            return sum
        }
    }

    // MARK: - One call

    /// The height at `date` from `constituents`. For many heights, make a `Station` once.
    public static func height(constituents: [Constituent], at date: Date) throws(Failure) -> Double {
        try Station(constituents: constituents).height(at: date)
    }

    /// The first high and the first low after `start`.
    public static func nextExtremes(constituents: [Constituent], after start: Date) throws(Failure) -> Extremes {
        try Station(constituents: constituents).nextExtremes(after: start)
    }

    // MARK: - Constituents

    /// The multipliers of T, s, h, p and p₁ in V, with its constant in degrees; of ξ, ν,
    /// ν′, 2ν″, Q and R in u; and which node factor f takes. SP 98 table 2.
    private struct Basic {
        var v: [Double]
        var u: [Double]
        var f: NodeFactor
    }

    private enum NodeFactor {
        case one, f73, f74, f75, f76, f77, f78, f149, f206, f215, f227, f235
    }

    private enum Recipe {
        case basic(Basic)
        /// A sum of other constituents: u is the sum of theirs, f the product.
        case compound([(String, Double)])
    }

    private static func basic(_ v: [Double], _ u: [Double], _ f: NodeFactor) -> Recipe {
        .basic(Basic(v: v, u: u + Array(repeating: 0, count: 6 - u.count), f: f))
    }

    //                          T   s   h   p  p₁   c        ξ   ν  ν′ 2ν″  Q   R
    private static let recipes: [(name: String, recipe: Recipe)] = [
        ("M2", basic([2, -2, 2, 0, 0, 0], [2, -2], .f78)),
        ("S2", basic([2, 0, 0, 0, 0, 0], [], .one)),
        ("N2", basic([2, -3, 2, 1, 0, 0], [2, -2], .f78)),
        ("K1", basic([1, 0, 1, 0, 0, -90], [0, 0, -1], .f227)),
        ("M4", .compound([("M2", 2)])),
        ("O1", basic([1, -2, 1, 0, 0, 90], [2, -1], .f75)),
        ("M6", .compound([("M2", 3)])),
        ("MK3", .compound([("M2", 1), ("K1", 1)])),
        ("S4", .compound([("S2", 2)])),
        ("MN4", .compound([("M2", 1), ("N2", 1)])),
        ("NU2", basic([2, -3, 4, -1, 0, 0], [2, -2], .f78)),
        ("S6", .compound([("S2", 3)])),
        ("MU2", basic([2, -4, 4, 0, 0, 0], [2, -2], .f78)),
        ("2N2", basic([2, -4, 2, 2, 0, 0], [2, -2], .f78)),
        ("OO1", basic([1, 2, 1, 0, 0, -90], [-2, -1], .f77)),
        ("LAM2", basic([2, -1, 0, 1, 0, 180], [2, -2], .f78)),
        ("S1", basic([1, 0, 0, 0, 0, 0], [], .one)),
        // SP 98's second form: p goes into Q, and the speed takes p's rate back (p. 42).
        ("M1", basic([1, -1, 1, 0, 0, -90], [1, -1, 0, 0, 1], .f206)),
        ("J1", basic([1, 1, 1, -1, 0, -90], [0, -1], .f76)),
        ("MM", basic([0, 1, 0, -1, 0, 0], [], .f73)),
        ("SSA", basic([0, 0, 2, 0, 0, 0], [], .one)),
        ("SA", basic([0, 0, 1, 0, 0, 0], [], .one)),
        // S2 − M2, not table 2's formula (SP 98 p. 48), so u isn't zero.
        ("MSF", .compound([("S2", 1), ("M2", -1)])),
        ("MF", basic([0, 2, 0, 0, 0, 0], [-2], .f74)),
        ("RHO", basic([1, -3, 3, -1, 0, 90], [2, -1], .f75)),
        ("Q1", basic([1, -3, 1, 1, 0, 90], [2, -1], .f75)),
        ("T2", basic([2, 0, -1, 0, 1, 0], [], .one)),
        ("R2", basic([2, 0, 1, 0, -1, 180], [], .one)),
        ("2Q1", basic([1, -4, 1, 2, 0, 90], [2, -1], .f75)),
        ("P1", basic([1, 0, -1, 0, 0, 90], [], .one)),
        ("2SM2", .compound([("S2", 2), ("M2", -1)])),
        ("M3", basic([3, -3, 3, 0, 0, 0], [3, -3], .f149)),
        ("L2", basic([2, -1, 2, -1, 0, 180], [2, -2, 0, 0, 0, -1], .f215)),
        // 2M2 − K1 (table 2a), not M2 + O1.
        ("2MK3", .compound([("M2", 2), ("K1", -1)])),
        ("K2", basic([2, 0, 2, 0, 0, 0], [0, 0, 0, -1], .f235)),
        ("M8", .compound([("M2", 4)])),
        ("MS4", .compound([("M2", 1), ("S2", 1)])),
    ]

    private static let index: [String: Int] = Dictionary(uniqueKeysWithValues: names.enumerated().map { ($1, $0) })

    // MARK: - Astronomy

    /// Seconds from 1970 to SP 98 table 1's epoch, 1899-12-31 12:00 UTC, and a Julian century.
    private static let epoch = -2_209_032_000.0, century = 3_155_760_000.0

    /// T, s, h, p and p₁ in degrees and c = 1, at `seconds` since 1970. SP 98 table 1.
    private static func vTerms(_ seconds: Double) -> [Double] {
        let c = (seconds - epoch) / century, c2 = c * c, c3 = c2 * c
        return [
            36525 * 360 * c,
            270 + 26.0 / 60 + 14.72 / 3600 + (1336 * 360 + 1_108_411.2 / 3600) * c + 9.09 / 3600 * c2 + 0.0068 / 3600 * c3,
            279 + 41.0 / 60 + 48.04 / 3600 + 129_602_768.13 / 3600 * c + 1.089 / 3600 * c2,
            334 + 19.0 / 60 + 40.87 / 3600 + (11 * 360 + 392_515.94 / 3600) * c - 37.24 / 3600 * c2 - 0.045 / 3600 * c3,
            281 + 13.0 / 60 + 15.0 / 3600 + 6189.03 / 3600 * c + 1.63 / 3600 * c2 + 0.012 / 3600 * c3,
            1,
        ]
    }

    /// Degrees per hour of T, s, h, p and p₁, at the epoch.
    private static let rates: [Double] = [15, (1336 * 360 + 1_108_411.2 / 3600) / 876_600, 129_602_768.13 / 3600 / 876_600,
                                          (11 * 360 + 392_515.94 / 3600) / 876_600, 6189.03 / 3600 / 876_600, 0]

    /// Speeds in radians per hour, in `names` order.
    private static let speeds: [Double] = {
        var speed: [String: Double] = [:]
        for (name, recipe) in recipes {
            switch recipe {
            case .basic(let b):
                speed[name] = zip(b.v, rates).reduce(0) { $0 + $1.0 * $1.1 } + b.u[4] * rates[3]
            case .compound(let parts):
                speed[name] = parts.reduce(0) { $0 + $1.1 * speed[$1.0]! }
            }
        }
        return names.map { radians(speed[$0]!) }
    }()

    /// V₀+u in radians and f, in `names` order, for one year.
    private struct YearTerms: Sendable {
        var start: Double
        var vu: [Double]
        var f: [Double]
    }

    private static func yearTerms(_ year: Int) -> YearTerms {
        let start = startOfYear(year), middle = (start + startOfYear(year + 1)) / 2
        let v = vTerms(start)

        // The moon's orbit at mid-year: SP 98 figure 1 and formulas 191 to 235.
        let mid = vTerms(middle), p = mid[3]
        let c = (middle - epoch) / century
        let n = 259 + 10.0 / 60 + 57.12 / 3600 - (5 * 360 + 482_912.63 / 3600) * c + 7.58 / 3600 * c * c + 0.008 / 3600 * c * c * c
        let omega = radians(23 + 27.0 / 60 + 8.26 / 3600), inclination = radians(5 + 8.0 / 60 + 43.3546 / 3600)
        let nr = radians(n)
        let cosI = cos(omega) * cos(inclination) - sin(omega) * sin(inclination) * cos(nr)
        let i = acos(cosI), sinI = sin(i)
        let sinNu = sin(inclination) * sin(nr) / sinI, nu = asin(sinNu)
        let sinBigOmega = sin(omega) * sin(nr) / sinI
        let cosBigOmega = cos(nr) * cos(nu) + sin(nr) * sinNu * cos(omega)
        let xi = nr - atan2(sinBigOmega, cosBigOmega)
        let nuPrime = atan2(sin(2 * i) * sin(nu), sin(2 * i) * cos(nu) + 0.3347)
        let twoNuSecond = atan2(sinI * sinI * sin(2 * nu), sinI * sinI * cos(2 * nu) + 0.0727)
        let bigP = radians(p) - xi
        let q = atan2(0.483 * sin(bigP), cos(bigP))
        let cotHalfI = 1 / tan(i / 2), tanHalfI = tan(i / 2)
        let r = atan2(sin(2 * bigP), cotHalfI * cotHalfI / 6 - cos(2 * bigP))
        let uTerms = [xi, nu, nuPrime, twoNuSecond, q, r]

        func f(_ factor: NodeFactor) -> Double {
            let f75 = sinI * pow(cos(i / 2), 2) / 0.38, f78 = pow(cos(i / 2), 4) / 0.9154
            switch factor {
            case .one: return 1
            case .f73: return (2.0 / 3 - sinI * sinI) / 0.5021
            case .f74: return sinI * sinI / 0.1578
            case .f75: return f75
            case .f76: return sin(2 * i) / 0.7214
            case .f77: return sinI * pow(sin(i / 2), 2) / 0.0164
            case .f78: return f78
            case .f149: return pow(cos(i / 2), 6) / 0.8758
            // f(O1)/Qa and f(M2)/Ra: formulas 197, 206 and 207, and 213 and 215.
            case .f206: return f75 * (2.31 + 1.435 * cos(2 * bigP)).squareRoot()
            case .f215:
                let t = tanHalfI * tanHalfI
                return f78 * (1 - 12 * t * cos(2 * bigP) + 36 * t * t).squareRoot()
            case .f227:
                let s = sin(2 * i)
                return (0.8965 * s * s + 0.6001 * s * cos(nu) + 0.1006).squareRoot()
            case .f235:
                let s = sinI * sinI
                return (19.0444 * s * s + 2.7702 * s * cos(2 * nu) + 0.0981).squareRoot()
            }
        }

        var vu: [String: Double] = [:], factor: [String: Double] = [:]
        for (name, recipe) in recipes {
            switch recipe {
            case .basic(let b):
                let degrees = zip(b.v, v).reduce(0) { $0 + $1.0 * ($1.1.truncatingRemainder(dividingBy: 360)) }
                vu[name] = radians(degrees) + zip(b.u, uTerms).reduce(0) { $0 + $1.0 * $1.1 }
                factor[name] = f(b.f)
            case .compound(let parts):
                vu[name] = parts.reduce(0) { $0 + $1.1 * vu[$1.0]! }
                factor[name] = parts.reduce(1) { $0 * pow(factor[$1.0]!, abs($1.1)) }
            }
        }
        return YearTerms(start: start,
                         vu: names.map { vu[$0]!.truncatingRemainder(dividingBy: 2 * .pi) },
                         f: names.map { factor[$0]! })
    }

    // MARK: - Calendar

    /// Seconds from 1970 to 00:00 UTC on 1 January of `year`, Gregorian.
    private static func startOfYear(_ year: Int) -> Double {
        let y = year - 1
        let days = 365 * y + y / 4 - y / 100 + y / 400 - 719_162
        return Double(days) * 86400
    }

    private static func yearAndHours(_ date: Date) throws(Failure) -> (YearTerms, Double) {
        let seconds = date.timeIntervalSince1970
        guard seconds.isFinite else { throw .outOfRange }
        var year = 1970 + Int((seconds / (365.2425 * 86400)).rounded(.down))
        if seconds < startOfYear(year) { year -= 1 } else if seconds >= startOfYear(year + 1) { year += 1 }
        guard years.contains(year) else { throw .outOfRange }
        let terms = cache.terms(year)
        return (terms, (seconds - terms.start) / 3600)
    }

    /// One year's V₀+u and f, worked out once and kept: a predictor asks for the same few years.
    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var years: [Int: YearTerms] = [:]

        func terms(_ year: Int) -> YearTerms {
            lock.lock()
            defer { lock.unlock() }
            if let terms = years[year] { return terms }
            let terms = TidePrediction.yearTerms(year)
            years[year] = terms
            return terms
        }
    }

    private static let cache = Cache()

    private static func radians(_ degrees: Double) -> Double { degrees * .pi / 180 }
}
