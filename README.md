# Algorithms in Swift

Swift implementations of the algorithms on [algorithms.gshaw.ca](https://algorithms.gshaw.ca),
each one self-contained file, held to the site's test data on every push and weekly.
Made from [algorithms-template](https://github.com/gshaw/algorithms-template).

| Algorithm | File | Status |
| --- | --- | --- |
| [Magnetic declination](https://algorithms.gshaw.ca/wmm/) | [WorldMagneticModel.swift](Sources/WMM/WorldMagneticModel.swift) | See [conformance.json](conformance.json) |
| [UTM and MGRS](https://algorithms.gshaw.ca/utm-mgrs/) | [GridReference.swift](Sources/UTMMGRS/GridReference.swift) | See [conformance.json](conformance.json) |

## Use one

Copy the file into your app, or add this package and depend on its product.

```swift
let field = try WorldMagneticModel.field(
    latitude: 49.3, longitude: -123.1, heightInKilometers: 0,
    decimalYear: WorldMagneticModel.decimalYear(for: .now)
)
let trueBearing = compassBearing + field.declination  // east positive
if field.blackout != .none { /* warn: the compass is unreliable here */ }
```

WMM2025 runs out at 2030.0. After that, `field` throws `outOfRange`; replace the file
when NOAA publishes WMM2030.

## Check it

```sh
mise install
mise run test   # every case against the current test data; writes conformance.json
```

`mise run evaluate` is the harness the checker drives, in `Sources/evaluate`.

## Licence

MIT. The WMM coefficients are NOAA's, public domain.
