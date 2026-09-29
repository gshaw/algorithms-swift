// Reads cases from algorithms.gshaw.ca as JSON Lines on standard input and writes one
// result per line. See https://algorithms.gshaw.ca/format/#implementations.

import AstronomicalTime
import Bearings
import Foundation
import Moon
import Sun
import UTMMGRS
import WMM

enum Failure: Error {
    case notImplemented, invalidInput, outOfRange
}

func number(_ input: [String: Any], _ name: String) throws -> Double {
    guard let value = input[name] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() else { throw Failure.invalidInput }
    return value.doubleValue
}

func integer(_ input: [String: Any], _ name: String) throws -> Int {
    let value = try number(input, name)
    guard let whole = Int(exactly: value) else { throw Failure.invalidInput }
    return whole
}

func string(_ input: [String: Any], _ name: String) throws -> String {
    guard let value = input[name] as? String else { throw Failure.invalidInput }
    return value
}

func wmm(_ operation: String, _ input: [String: Any]) throws -> [String: Any] {
    do {
        switch operation {
        case "field":
            let field = try WorldMagneticModel.field(
                latitude: number(input, "latitudeInDegrees"),
                longitude: number(input, "longitudeInDegrees"),
                heightInKilometers: number(input, "heightInKilometers"),
                decimalYear: number(input, "decimalYear")
            )
            return [
                "magneticDeclinationInDegrees": field.declination,
                "inclinationInDegrees": field.inclination,
                "northIntensityInNanoteslas": field.north,
                "eastIntensityInNanoteslas": field.east,
                "downIntensityInNanoteslas": field.down,
                "horizontalIntensityInNanoteslas": field.horizontal,
                "totalIntensityInNanoteslas": field.total,
                "gridVariationInDegrees": field.gridVariation.map { $0 as Any } ?? NSNull(),
                "blackout": field.blackout.rawValue,
            ]
        case "decimalYear":
            let parts = try string(input, "date").split(separator: "-", omittingEmptySubsequences: false)
            guard parts.count == 3, let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) else {
                throw Failure.invalidInput
            }
            return ["decimalYear": try WorldMagneticModel.decimalYear(year: year, month: month, day: day)]
        default:
            throw Failure.notImplemented
        }
    } catch let failure as WorldMagneticModel.Failure {
        throw failure == .outOfRange ? Failure.outOfRange : Failure.invalidInput
    }
}

func utmMgrs(_ operation: String, _ input: [String: Any]) throws -> [String: Any] {
    func coordinate(_ c: GridReference.Coordinate) -> [String: Any] {
        ["latitudeInDegrees": c.latitude, "longitudeInDegrees": c.longitude]
    }
    do {
        switch operation {
        case "toUtm":
            let p = try GridReference.toUTM(latitude: number(input, "latitudeInDegrees"), longitude: number(input, "longitudeInDegrees"))
            return [
                "zone": p.zone, "hemisphere": p.hemisphere.rawValue,
                "eastingInMeters": p.easting, "northingInMeters": p.northing,
                "convergenceInDegrees": p.convergence, "pointScale": p.pointScale,
            ]
        case "fromUtm":
            guard let hemisphere = GridReference.Hemisphere(rawValue: try string(input, "hemisphere")) else { throw Failure.invalidInput }
            return coordinate(try GridReference.fromUTM(
                zone: integer(input, "zone"), hemisphere: hemisphere,
                easting: number(input, "eastingInMeters"), northing: number(input, "northingInMeters")))
        case "toMgrs":
            return ["mgrs": try GridReference.toMGRS(
                latitude: number(input, "latitudeInDegrees"), longitude: number(input, "longitudeInDegrees"),
                precision: integer(input, "precisionInDigits"))]
        case "fromMgrs":
            return coordinate(try GridReference.fromMGRS(string(input, "mgrs")))
        case "parse":
            return coordinate(try GridReference.parse(string(input, "text")))
        default:
            throw Failure.notImplemented
        }
    } catch let failure as GridReference.Failure {
        throw failure == .outOfRange ? Failure.outOfRange : Failure.invalidInput
    }
}

func bearings(_ operation: String, _ input: [String: Any]) throws -> [String: Any] {
    func north(_ name: String) throws -> Bearings.North {
        guard let value = Bearings.North(rawValue: try string(input, name)) else { throw Failure.invalidInput }
        return value
    }
    do {
        switch operation {
        case "inverse":
            let r = try Bearings.inverse(
                fromLatitude: number(input, "fromLatitudeInDegrees"), fromLongitude: number(input, "fromLongitudeInDegrees"),
                toLatitude: number(input, "toLatitudeInDegrees"), toLongitude: number(input, "toLongitudeInDegrees"))
            return ["distanceInMeters": r.distance, "bearingInDegrees": r.bearing]
        case "destination":
            let r = try Bearings.destination(
                fromLatitude: number(input, "fromLatitudeInDegrees"), fromLongitude: number(input, "fromLongitudeInDegrees"),
                distance: number(input, "distanceInMeters"), bearing: number(input, "bearingInDegrees"))
            return ["toLatitudeInDegrees": r.latitude, "toLongitudeInDegrees": r.longitude]
        case "backAzimuth":
            return ["backAzimuthInDegrees": Bearings.backAzimuth(try number(input, "bearingInDegrees"))]
        case "turn":
            let r = Bearings.turn(from: try number(input, "fromBearingInDegrees"), to: try number(input, "toBearingInDegrees"))
            return ["turnInDegrees": r.degrees, "direction": r.direction.rawValue]
        case "convertNorth":
            return ["convertedBearingInDegrees": Bearings.convert(
                try number(input, "bearingInDegrees"), from: try north("fromNorth"), to: try north("toNorth"),
                declination: try number(input, "magneticDeclinationInDegrees"), convergence: try number(input, "convergenceInDegrees"))]
        case "formatBearing":
            guard let unit = Bearings.AngleUnit(rawValue: try string(input, "angleUnit")) else { throw Failure.invalidInput }
            return ["bearingText": Bearings.format(try number(input, "bearingInDegrees"), unit: unit)]
        case "compassPoint":
            return ["compassPointText": try Bearings.compassPoint(try number(input, "bearingInDegrees"), points: try integer(input, "pointCount"))]
        default:
            throw Failure.notImplemented
        }
    } catch let failure as Bearings.Failure {
        throw failure == .outOfRange ? Failure.outOfRange : Failure.invalidInput
    }
}

func astronomicalTime(_ operation: String, _ input: [String: Any]) throws -> [String: Any] {
    do {
        switch operation {
        case "julianDay":
            return ["julianDay": try AstronomicalTime.julianDay(instant: string(input, "instantUtc"))]
        case "calendarDate":
            let date = try AstronomicalTime.calendarDate(julianDay: number(input, "julianDay"))
            return ["date": date.text, "calendar": date.calendar.rawValue]
        case "deltaT":
            return ["deltaTInSeconds": try AstronomicalTime.deltaT(decimalYear: number(input, "decimalYear"))]
        case "siderealTime":
            let jd = try AstronomicalTime.julianDay(instant: string(input, "instantUtc"))
            let s = AstronomicalTime.siderealTime(julianDay: jd, longitude: try number(input, "longitudeInDegrees"))
            return ["greenwichSiderealTimeInHours": s.greenwich, "localSiderealTimeInHours": s.local]
        case "horizontal":
            let jd = try AstronomicalTime.julianDay(instant: string(input, "instantUtc"))
            let h = try AstronomicalTime.horizontal(
                rightAscension: number(input, "rightAscensionInHours"), declination: number(input, "declinationInDegrees"),
                latitude: number(input, "latitudeInDegrees"), longitude: number(input, "longitudeInDegrees"), julianDay: jd)
            return ["azimuthInDegrees": h.azimuth, "altitudeInDegrees": h.altitude]
        default:
            throw Failure.notImplemented
        }
    } catch let failure as AstronomicalTime.Failure {
        throw failure == .outOfRange ? Failure.outOfRange : Failure.invalidInput
    }
}

func instant(_ input: [String: Any], _ name: String) throws -> Date {
    let formatter = ISO8601DateFormatter()
    guard let date = formatter.date(from: try string(input, name)) else { throw Failure.invalidInput }
    return date
}

func iso(_ date: Date?) -> Any {
    guard let date else { return NSNull() }
    let formatter = ISO8601DateFormatter()
    return formatter.string(from: Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded()))
}

func sun(_ operation: String, _ input: [String: Any]) throws -> [String: Any] {
    do {
        switch operation {
        case "position":
            let p = try Sun.position(latitude: number(input, "latitudeInDegrees"), longitude: number(input, "longitudeInDegrees"),
                                     at: instant(input, "instantUtc"))
            return ["azimuthInDegrees": p.azimuth, "altitudeInDegrees": p.altitude]
        case "events":
            let e = try Sun.events(latitude: number(input, "latitudeInDegrees"), longitude: number(input, "longitudeInDegrees"),
                                   start: instant(input, "startUtc"), hours: number(input, "windowInHours"))
            return [
                "riseUtc": iso(e.rise), "setUtc": iso(e.set), "transitUtc": iso(e.transit),
                "civilDawnUtc": iso(e.civilDawn), "civilDuskUtc": iso(e.civilDusk),
                "nauticalDawnUtc": iso(e.nauticalDawn), "nauticalDuskUtc": iso(e.nauticalDusk),
                "astronomicalDawnUtc": iso(e.astronomicalDawn), "astronomicalDuskUtc": iso(e.astronomicalDusk),
                "isAlwaysUp": e.isAlwaysUp, "isAlwaysDown": e.isAlwaysDown,
            ]
        default:
            throw Failure.notImplemented
        }
    } catch let failure as Sun.Failure {
        throw failure == .outOfRange ? Failure.outOfRange : Failure.invalidInput
    }
}

func moon(_ operation: String, _ input: [String: Any]) throws -> [String: Any] {
    do {
        switch operation {
        case "events":
            let e = try Moon.events(latitude: number(input, "latitudeInDegrees"), longitude: number(input, "longitudeInDegrees"),
                                    start: instant(input, "startUtc"), hours: number(input, "windowInHours"))
            return ["riseUtc": iso(e.rise), "setUtc": iso(e.set), "transitUtc": iso(e.transit),
                    "isAlwaysUp": e.isAlwaysUp, "isAlwaysDown": e.isAlwaysDown]
        case "phase":
            let p = Moon.phase(at: try instant(input, "instantUtc"))
            return ["illuminationFraction": p.illumination, "phaseAngleInDegrees": p.phaseAngle, "phaseName": p.name.rawValue]
        case "nextPhases":
            let n = Moon.nextPhases(after: try instant(input, "startUtc"))
            return ["newMoonUtc": iso(n.newMoon), "firstQuarterUtc": iso(n.firstQuarter),
                    "fullMoonUtc": iso(n.fullMoon), "lastQuarterUtc": iso(n.lastQuarter)]
        default:
            throw Failure.notImplemented
        }
    } catch let failure as Moon.Failure {
        throw failure == .outOfRange ? Failure.outOfRange : Failure.invalidInput
    }
}

while let line = readLine() {
    guard let data = line.data(using: .utf8),
          let query = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let id = query["id"] as? String else { continue }
    var reply: [String: Any] = ["id": id]
    do {
        let input = query["input"] as? [String: Any] ?? [:]
        let operation = query["operation"] as? String ?? ""
        switch query["algorithm"] as? String {
        case "wmm": reply["output"] = try wmm(operation, input)
        case "utm-mgrs": reply["output"] = try utmMgrs(operation, input)
        case "bearings": reply["output"] = try bearings(operation, input)
        case "astronomical-time": reply["output"] = try astronomicalTime(operation, input)
        case "sun": reply["output"] = try sun(operation, input)
        case "moon": reply["output"] = try moon(operation, input)
        default: throw Failure.notImplemented
        }
    } catch let failure as Failure {
        reply["error"] = "\(failure)"
    } catch {
        reply["error"] = "invalidInput"
    }
    let out = try JSONSerialization.data(withJSONObject: reply, options: [.sortedKeys])
    print(String(decoding: out, as: UTF8.self))
}
