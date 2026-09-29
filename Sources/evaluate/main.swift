// Reads cases from algorithms.gshaw.ca as JSON Lines on standard input and writes one
// result per line. See https://algorithms.gshaw.ca/format/#implementations.

import Foundation
import WMM

enum Failure: Error {
    case notImplemented, invalidInput, outOfRange
}

func number(_ input: [String: Any], _ name: String) throws -> Double {
    guard let value = input[name] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() else { throw Failure.invalidInput }
    return value.doubleValue
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
