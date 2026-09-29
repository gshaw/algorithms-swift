// UTM, UPS and MGRS grid references on WGS84, and typed coordinates parsed. One
// self-contained file: copy it into an app as it is.
//
// Held to https://algorithms.gshaw.ca/utm-mgrs/ by https://github.com/gshaw/algorithms-swift.
// The projection is the Krüger series to sixth order from C. F. F. Karney, "Transverse
// Mercator with an accuracy of a few nanometers" (2011); the zone rules, MGRS lettering
// and parsing follow GeographicLib, the reference the test data comes from.

import Foundation

public enum GridReference {
    public enum Hemisphere: String, Sendable {
        case north, south
    }

    public enum Failure: Error, Equatable, Sendable {
        case outOfRange
        case invalidInput
    }

    /// A UTM or UPS position. `zone` is 1 to 60, or 0 for UPS.
    public struct Position: Equatable, Sendable {
        public var zone: Int
        public var hemisphere: Hemisphere
        public var easting: Double
        public var northing: Double
        /// Degrees clockwise from true north to grid north.
        public var convergence: Double
        public var pointScale: Double
    }

    public struct Coordinate: Equatable, Sendable {
        public var latitude: Double
        public var longitude: Double
    }

    // MARK: - UTM and UPS

    /// The UTM or UPS position of a point, in its standard zone, with the Norway and
    /// Svalbard exceptions. UPS from 84° N and south of 80° S.
    public static func toUTM(latitude: Double, longitude: Double) throws(Failure) -> Position {
        guard (-90...90).contains(latitude), (-180...180).contains(longitude) else { throw .outOfRange }
        let hemisphere: Hemisphere = latitude >= 0 ? .north : .south
        let zone = standardZone(latitude: latitude, longitude: longitude)
        if zone == 0 {
            let p = PolarStereographic.forward(north: hemisphere == .north, latitude: latitude, longitude: longitude)
            return Position(zone: 0, hemisphere: hemisphere, easting: p.x + upsFalse, northing: p.y + upsFalse,
                            convergence: p.gamma, pointScale: p.k)
        }
        let t = TransverseMercator.forward(centralMeridian: centralMeridian(zone), latitude: latitude, longitude: longitude)
        return Position(zone: zone, hemisphere: hemisphere, easting: t.x + utmFalseEasting,
                        northing: t.y + (hemisphere == .south ? utmFalseNorthingSouth : 0),
                        convergence: t.gamma, pointScale: t.k)
    }

    /// The point at a UTM or UPS position. Eastings and northings may run 100 km past
    /// the zone's MGRS limits, as GeographicLib allows.
    public static func fromUTM(zone: Int, hemisphere: Hemisphere, easting: Double, northing: Double) throws(Failure) -> Coordinate {
        guard (0...60).contains(zone), easting.isFinite, northing.isFinite else { throw .outOfRange }
        let north = hemisphere == .north
        let ups = zone == 0
        // GeographicLib's limits in units of 100 km, with 100 km of slop each way.
        let (minE, maxE, minN, maxN): (Double, Double, Double, Double) =
            ups ? (north ? (13, 27, 13, 27) : (8, 32, 8, 32))
                : (north ? (1, 9, 0, 95) : (1, 9, 10, 100))
        guard easting >= (minE - 1) * tile, easting <= (maxE + 1) * tile,
              northing >= (minN - 1) * tile, northing <= (maxN + 1) * tile else { throw .outOfRange }
        if ups {
            let (lat, lon) = PolarStereographic.reverse(north: north, x: easting - upsFalse, y: northing - upsFalse)
            return Coordinate(latitude: lat, longitude: lon)
        }
        let (lat, lon) = TransverseMercator.reverse(
            centralMeridian: centralMeridian(zone),
            x: easting - utmFalseEasting,
            y: northing - (north ? 0 : utmFalseNorthingSouth))
        return Coordinate(latitude: lat, longitude: normalized(lon))
    }

    // MARK: - MGRS

    /// An MGRS reference with `precision` digits each for easting and northing, 0 to 5,
    /// truncated, never rounded. GeographicLib's form: the zone padded to two digits and
    /// no spaces, like 04QFJ1234567890.
    public static func toMGRS(latitude: Double, longitude: Double, precision: Int) throws(Failure) -> String {
        guard (0...5).contains(precision) else { throw .outOfRange }
        let p = try toUTM(latitude: latitude, longitude: longitude)
        let north = p.hemisphere == .north
        // Micrometres, as GeographicLib counts, so truncation is exact.
        let ix = Int64((p.easting * 1e6).rounded(.down)), iy = Int64((p.northing * 1e6).rounded(.down))
        let perTile: Int64 = 100_000 * 1_000_000
        let xh = Int(ix / perTile), yh = Int(iy / perTile)
        var result = ""
        if p.zone != 0 {
            let band = abs(latitude) < 1e-9 ? (north ? 0 : -1) : latitudeBand(latitude)
            result += String(format: "%02d", p.zone)
            result += letter(latitudeBands, 10 + band)
            result += letter(utmColumns[(p.zone - 1) % 3], xh - 1)
            result += letter(utmRows, (yh + ((p.zone - 1) & 1 == 1 ? 5 : 0)) % 20)
        } else {
            let east = xh >= 20
            let band = (north ? 2 : 0) + (east ? 1 : 0)
            let offset = north ? 13 : 8
            result += letter(upsBands, band)
            result += letter(upsColumns[band], xh - (east ? 20 : offset))
            result += letter(upsRows[north ? 1 : 0], yh - offset)
        }
        if precision > 0 {
            var divisor: Int64 = 1
            for _ in 0..<(11 - precision) { divisor *= 10 }
            let e = (ix - perTile * Int64(xh)) / divisor, n = (iy - perTile * Int64(yh)) / divisor
            let digits = "%0\(precision)lld"
            result += String(format: digits, e) + String(format: digits, n)
        }
        return result
    }

    /// The centre of an MGRS reference's square. Takes GeographicLib's form, an unpadded
    /// zone and lower case; no spaces.
    public static func fromMGRS(_ text: String) throws(Failure) -> Coordinate {
        let chars = Array(text.uppercased())
        var i = 0
        var zone = 0
        while i < chars.count, let digit = chars[i].wholeNumberValue, chars[i].isASCII {
            zone = zone * 10 + digit
            i += 1
        }
        guard i <= 2, chars.count - i >= 3 else { throw .invalidInput }
        if i > 0 && !(1...60).contains(zone) { throw .invalidInput }
        let utm = i > 0
        let bands = utm ? latitudeBands : upsBands
        guard var band = bands.firstIndex(of: chars[i]) else { throw .invalidInput }
        let north = band >= (utm ? 10 : 2)
        let columns = utm ? utmColumns[(zone - 1) % 3] : upsColumns[band]
        let rows = utm ? utmRows : upsRows[north ? 1 : 0]
        guard var column = columns.firstIndex(of: chars[i + 1]), var row = rows.firstIndex(of: chars[i + 2]) else {
            throw .invalidInput
        }
        i += 3
        if utm {
            if (zone - 1) & 1 == 1 { row = (row + 20 - 5) % 20 }
            band -= 10
            guard let r = utmRow(band: band, column: column, row: row) else { throw .invalidInput }
            row = north ? r : r + 100
            column += 1
        } else {
            let east = band & 1 == 1
            column += east ? 20 : (north ? 13 : 8)
            row += north ? 13 : 8
        }
        let rest = chars[i...]
        guard rest.count % 2 == 0, rest.count <= 22, rest.allSatisfy({ $0.isASCII && $0.isNumber }) else { throw .invalidInput }
        let precision = rest.count / 2
        var unit = 1.0, x = Double(column), y = Double(row)
        for k in 0..<precision {
            unit *= 10
            x = 10 * x + Double(rest[rest.startIndex + k].wholeNumberValue!)
            y = 10 * y + Double(rest[rest.startIndex + precision + k].wholeNumberValue!)
        }
        // The centre of the square.
        unit *= 2
        x = 2 * x + 1
        y = 2 * y + 1
        return try fromUTM(zone: utm ? zone : 0, hemisphere: north ? .north : .south,
                           easting: tile * x / unit, northing: tile * y / unit)
    }

    // MARK: - Typed coordinates

    /// A coordinate as a person types it: two angles in decimal degrees, degrees and
    /// minutes, or degrees, minutes and seconds, with hemisphere letters before or after;
    /// UTM or UPS as `10n 491221 5458889`; or an MGRS reference.
    public static func parse(_ text: String) throws(Failure) -> Coordinate {
        let parts = text.split(whereSeparator: { $0.isWhitespace || $0 == "," }).map(String.init)
        switch parts.count {
        case 1:
            return try fromMGRS(parts[0])
        case 2:
            let a = try angle(parts[0]), b = try angle(parts[1])
            var latitude: Double, longitude: Double
            switch (a.kind, b.kind) {
            case (.latitude, .latitude), (.longitude, .longitude): throw .invalidInput
            case (.longitude, _), (_, .latitude): (latitude, longitude) = (b.value, a.value)
            default: (latitude, longitude) = (a.value, b.value)
            }
            guard (-90...90).contains(latitude) else { throw .outOfRange }
            longitude = normalized(longitude)
            return Coordinate(latitude: latitude, longitude: longitude)
        case 3:
            let zoneFirst = parts[0].last?.isLetter == true
            guard zoneFirst || parts[2].last?.isLetter == true else { throw .invalidInput }
            let zoneText = zoneFirst ? parts[0] : parts[2]
            let numbers = zoneFirst ? [parts[1], parts[2]] : [parts[0], parts[1]]
            guard let easting = Double(numbers[0]), let northing = Double(numbers[1]) else { throw .invalidInput }
            let digits = zoneText.prefix { $0.isASCII && $0.isNumber }
            let word = zoneText.dropFirst(digits.count).lowercased()
            guard digits.count <= 2, let hemisphere: Hemisphere = ["n": .north, "north": .north, "s": .south, "south": .south][word]
            else { throw .invalidInput }
            let zone = digits.isEmpty ? 0 : Int(digits)!
            guard digits.isEmpty || (1...60).contains(zone) else { throw .outOfRange }
            return try fromUTM(zone: zone, hemisphere: hemisphere, easting: easting, northing: northing)
        default:
            throw .invalidInput
        }
    }

    private enum AngleKind { case none, latitude, longitude }

    /// One angle: an optional sign or hemisphere letter at either end, then degrees, with
    /// optional minutes and seconds marked by ° ' " (or d, and their typographic forms) or
    /// separated by colons.
    private static func angle(_ raw: String) throws(Failure) -> (value: Double, kind: AngleKind) {
        var text = raw
        for (from, to) in [("º", "°"), ("⁰", "°"), ("˚", "°"), ("d", "°"), ("D", "°"), ("*", "°"),
                           ("′", "'"), ("‘", "'"), ("’", "'"), ("´", "'"),
                           ("″", "\""), ("”", "\""), ("''", "\"")] {
            text = text.replacingOccurrences(of: from, with: to)
        }
        var sign = 1.0
        var kind = AngleKind.none
        func hemisphere(_ c: Character) -> Bool {
            switch c.uppercased() {
            case "N": kind = .latitude
            case "S": kind = .latitude; sign = -sign
            case "E": kind = .longitude
            case "W": kind = .longitude; sign = -sign
            default: return false
            }
            return true
        }
        if let first = text.first, hemisphere(first) { text.removeFirst() }
        else if let last = text.last, hemisphere(last) { text.removeLast() }
        if text.first == "-" || text.first == "+" {
            guard kind == .none else { throw .invalidInput }
            if text.removeFirst() == "-" { sign = -1 }
        }
        guard !text.isEmpty else { throw .invalidInput }

        var pieces: [Double] = []
        if text.contains(":") {
            let fields = text.split(separator: ":", omittingEmptySubsequences: false)
            guard fields.count <= 3 else { throw .invalidInput }
            for field in fields {
                guard let v = Double(field), v >= 0 else { throw .invalidInput }
                pieces.append(v)
            }
        } else {
            var number = ""
            var slot = 0
            for c in text {
                let marker: Int? = c == "°" ? 0 : c == "'" ? 1 : c == "\"" ? 2 : nil
                if let marker {
                    guard marker >= slot, let v = Double(number) else { throw .invalidInput }
                    while pieces.count < marker { pieces.append(0) }
                    pieces.append(v)
                    number = ""
                    slot = marker + 1
                } else if c.isASCII && (c.isNumber || c == ".") {
                    number.append(c)
                } else {
                    throw .invalidInput
                }
            }
            if !number.isEmpty {
                guard let v = Double(number), slot < 3 else { throw .invalidInput }
                while pieces.count < slot { pieces.append(0) }
                pieces.append(v)
            }
        }
        guard !pieces.isEmpty else { throw .invalidInput }
        if pieces.count > 1 { guard pieces[1] < 60 else { throw .invalidInput } }
        if pieces.count > 2 { guard pieces[2] < 60 else { throw .invalidInput } }
        let value = pieces.enumerated().reduce(0.0) { $0 + $1.element / pow(60, Double($1.offset)) }
        return (sign * value, kind)
    }

    // MARK: - Zones and lettering

    private static let tile = 100_000.0
    private static let utmFalseEasting = 500_000.0
    private static let utmFalseNorthingSouth = 10_000_000.0
    private static let upsFalse = 2_000_000.0

    private static let latitudeBands = Array("CDEFGHJKLMNPQRSTUVWX")
    private static let utmColumns = [Array("ABCDEFGH"), Array("JKLMNPQR"), Array("STUVWXYZ")]
    private static let utmRows = Array("ABCDEFGHJKLMNPQRSTUV")
    private static let upsBands = Array("ABYZ")
    private static let upsColumns = [Array("JKLPQRSTUXYZ"), Array("ABCFGHJKLPQR"), Array("RSTUXYZ"), Array("ABCFGHJ")]
    private static let upsRows = [Array("ABCDEFGHJKLMNPQRSTUVWXYZ"), Array("ABCDEFGHJKLMNP")]

    private static func letter(_ letters: [Character], _ index: Int) -> String { String(letters[index]) }

    private static func centralMeridian(_ zone: Int) -> Double { Double(6 * zone - 183) }

    private static func normalized(_ longitude: Double) -> Double {
        var value = longitude.truncatingRemainder(dividingBy: 360)
        if value >= 180 { value -= 360 } else if value < -180 { value += 360 }
        return value
    }

    /// The band index, −10 (C) to 9 (X).
    private static func latitudeBand(_ latitude: Double) -> Int {
        let ilat = Int(latitude.rounded(.down))
        return max(-10, min(9, (ilat + 80) / 8 - 10))
    }

    /// The zone, or 0 for UPS.
    private static func standardZone(latitude: Double, longitude: Double) -> Int {
        guard latitude < 84, latitude >= -80 else { return 0 }
        var ilon = Int(normalized(longitude).rounded(.down))
        if ilon == 180 { ilon = -180 }
        var zone = (ilon + 186) / 6
        let band = latitudeBand(latitude)
        if band == 7 && zone == 31 && ilon >= 3 {
            zone = 32  // Norway
        } else if band == 9 && ilon >= 0 && ilon < 42 {
            zone = 2 * ((ilon + 183) / 12) + 1  // Svalbard
        }
        return zone
    }

    /// The true row index, −90 to 94, for a periodic row in a band, or nil when the
    /// square isn't in the band. GeographicLib's MGRS::UTMRow.
    private static func utmRow(band: Int, column: Int, row: Int) -> Int? {
        let c = 100 * Double(8 * band + 4) / 90
        let north = band >= 0 ? 1.0 : 0.0
        let minRow = band > -10 ? Int((c - 4.3 - 0.1 * north).rounded(.down)) : -90
        let maxRow = band < 9 ? Int((c + 4.4 - 0.1 * north).rounded(.down)) : 94
        let baseRow = (minRow + maxRow) / 2 - 10
        let r = (row - baseRow + 100) % 20 + baseRow
        if r >= minRow && r <= maxRow { return r }
        let sBand = band >= 0 ? band : -band - 1
        let sRow = r >= 0 ? r : -r - 1
        let sCol = column < 4 ? column : -column + 7
        if (sRow == 70 && sBand == 8 && sCol >= 2) || (sRow == 71 && sBand == 7 && sCol <= 2) ||
            (sRow == 79 && sBand == 9 && sCol >= 1) || (sRow == 80 && sBand == 8 && sCol <= 1) {
            return r
        }
        return nil
    }
}

// MARK: - The projections

private let a = 6378137.0
private let f = 1 / 298.257223563
private let e2 = f * (2 - f)
private let e = e2.squareRoot()

/// τ′, the tangent of the conformal latitude, from τ, the tangent of the geographic one.
private func taup(_ tau: Double) -> Double {
    let tau1 = (1 + tau * tau).squareRoot()
    let sig = sinh(e * atanh(e * tau / tau1))
    return (1 + sig * sig).squareRoot() * tau - sig * tau1
}

/// τ from τ′, by Newton's method.
private func tauf(_ taup0: Double) -> Double {
    let e2m = 1 - e2
    var tau = taup0 / e2m
    for _ in 0..<10 {
        let t = taup(tau)
        let dtau = (taup0 - t) * (1 + e2m * tau * tau) / (e2m * (1 + tau * tau).squareRoot() * (1 + t * t).squareRoot())
        tau += dtau
        if abs(dtau) < 1e-15 * max(1, abs(tau)) { break }
    }
    return tau
}

private enum TransverseMercator {
    static let k0 = 0.9996
    static let n = f / (2 - f)
    static let b1 = (n * n * (n * n * (n * n + 4) + 64) + 256) / 256 / (1 + n)

    static let alpha: [Double] = {
        let n2 = n * n, n3 = n2 * n, n4 = n3 * n, n5 = n4 * n, n6 = n5 * n
        return [
            n / 2 - 2 * n2 / 3 + 5 * n3 / 16 + 41 * n4 / 180 - 127 * n5 / 288 + 7891 * n6 / 37800,
            13 * n2 / 48 - 3 * n3 / 5 + 557 * n4 / 1440 + 281 * n5 / 630 - 1983433 * n6 / 1935360,
            61 * n3 / 240 - 103 * n4 / 140 + 15061 * n5 / 26880 + 167603 * n6 / 181440,
            49561 * n4 / 161280 - 179 * n5 / 168 + 6601661 * n6 / 7257600,
            34729 * n5 / 80640 - 3418889 * n6 / 1995840,
            212378941 * n6 / 319334400,
        ]
    }()

    static let beta: [Double] = {
        let n2 = n * n, n3 = n2 * n, n4 = n3 * n, n5 = n4 * n, n6 = n5 * n
        return [
            n / 2 - 2 * n2 / 3 + 37 * n3 / 96 - n4 / 360 - 81 * n5 / 512 + 96199 * n6 / 604800,
            n2 / 48 + n3 / 15 - 437 * n4 / 1440 + 46 * n5 / 105 - 1118711 * n6 / 3870720,
            17 * n3 / 480 - 37 * n4 / 840 - 209 * n5 / 4480 + 5569 * n6 / 90720,
            4397 * n4 / 161280 - 11 * n5 / 504 - 830251 * n6 / 7257600,
            4583 * n5 / 161280 - 108847 * n6 / 3991680,
            20648693 * n6 / 638668800,
        ]
    }()

    static func forward(centralMeridian: Double, latitude: Double, longitude: Double) -> (x: Double, y: Double, gamma: Double, k: Double) {
        var dlon = (longitude - centralMeridian).truncatingRemainder(dividingBy: 360)
        if dlon > 180 { dlon -= 360 } else if dlon < -180 { dlon += 360 }
        let lam = dlon * .pi / 180
        let phi = latitude * .pi / 180
        let tau = tan(phi)
        let tp = taup(tau)
        let xip = atan2(tp, cos(lam))
        let etap = asinh(sin(lam) / (tp * tp + cos(lam) * cos(lam)).squareRoot())

        var xi = xip, eta = etap, p = 1.0, q = 0.0
        for j in 1...6 {
            let a = alpha[j - 1], t = 2 * Double(j)
            xi += a * sin(t * xip) * cosh(t * etap)
            eta += a * cos(t * xip) * sinh(t * etap)
            p += t * a * cos(t * xip) * cosh(t * etap)
            q += t * a * sin(t * xip) * sinh(t * etap)
        }
        let gamma = atan(tp / (1 + tp * tp).squareRoot() * tan(lam)) + atan2(q, p)
        let k = (1 - e2 * sin(phi) * sin(phi)).squareRoot() * (1 + tau * tau).squareRoot()
            / (tp * tp + cos(lam) * cos(lam)).squareRoot() * b1 * (p * p + q * q).squareRoot()
        return (k0 * a * b1 * eta, k0 * a * b1 * xi, gamma * 180 / .pi, k0 * k)
    }

    static func reverse(centralMeridian: Double, x: Double, y: Double) -> (latitude: Double, longitude: Double) {
        let xi = y / (k0 * a * b1), eta = x / (k0 * a * b1)
        var xip = xi, etap = eta
        for j in 1...6 {
            let b = beta[j - 1], t = 2 * Double(j)
            xip -= b * sin(t * xi) * cosh(t * eta)
            etap -= b * cos(t * xi) * sinh(t * eta)
        }
        let tp = sin(xip) / (sinh(etap) * sinh(etap) + cos(xip) * cos(xip)).squareRoot()
        let lam = atan2(sinh(etap), cos(xip))
        return (atan(tauf(tp)) * 180 / .pi, centralMeridian + lam * 180 / .pi)
    }
}

private enum PolarStereographic {
    static let k0 = 0.994
    static let c = (1 - f) * exp(e * atanh(e))

    static func forward(north: Bool, latitude: Double, longitude: Double) -> (x: Double, y: Double, gamma: Double, k: Double) {
        let lat = north ? latitude : -latitude
        var rho: Double, k: Double
        if lat == 90 {
            rho = 0
            k = k0
        } else {
            let tau = tan(lat * .pi / 180), secphi = (1 + tau * tau).squareRoot()
            let tp = taup(tau)
            rho = (1 + tp * tp).squareRoot() + abs(tp)
            rho = tp >= 0 ? 1 / rho : rho
            rho *= 2 * k0 * a / c
            k = rho / a * secphi * (1 - e2 + e2 / (secphi * secphi)).squareRoot()
        }
        let lon = longitude * .pi / 180
        let x = rho * sin(lon)
        let y = (north ? -rho : rho) * cos(lon)
        return (x, y, north ? longitude : -longitude, k)
    }

    static func reverse(north: Bool, x: Double, y: Double) -> (latitude: Double, longitude: Double) {
        let rho = (x * x + y * y).squareRoot()
        let t = rho != 0 ? rho / (2 * k0 * a / c) : Double.ulpOfOne * Double.ulpOfOne
        let tau = tauf((1 / t - t) / 2)
        let lat = (north ? 1 : -1) * atan(tau) * 180 / .pi
        let lon = atan2(x, north ? -y : y) * 180 / .pi
        return (lat, lon)
    }
}
