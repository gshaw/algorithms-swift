// The sun's position, rise, set, transit and the three twilights. One self-contained
// file: copy it into an app as it is.
//
// Held to https://algorithms.gshaw.ca/sun/ by https://github.com/gshaw/algorithms-swift.
// The sun's apparent place follows Meeus, Astronomical Algorithms, chapter 25's higher
// accuracy method, on VSOP87D (Bretagnon and Francou, 1988) from CDS catalogue VI/81,
// truncated to amplitudes of 1e-7. Events are found by searching the window.

import Foundation

public enum Sun {
    public enum Failure: Error, Equatable, Sendable {
        case outOfRange
        case invalidInput
    }

    public struct Events: Equatable, Sendable {
        public var rise: Date?
        public var set: Date?
        public var transit: Date?
        public var civilDawn: Date?
        public var civilDusk: Date?
        public var nauticalDawn: Date?
        public var nauticalDusk: Date?
        public var astronomicalDawn: Date?
        public var astronomicalDusk: Date?
        /// Above −0.833° for the whole window.
        public var isAlwaysUp: Bool
        /// Below −0.833° for the whole window.
        public var isAlwaysDown: Bool
    }

    /// Rise and set put the sun's centre here: its radius plus refraction at the horizon.
    public static let riseAltitude = -0.833

    /// Azimuth clockwise from north and geometric altitude of the sun's centre.
    public static func position(latitude: Double, longitude: Double, at date: Date) throws(Failure) -> (azimuth: Double, altitude: Double) {
        guard (-90...90).contains(latitude), (-180...180).contains(longitude) else { throw .outOfRange }
        let p = place(latitude: latitude, longitude: longitude, julianDay: julianDay(date))
        return (p.azimuth, p.altitude)
    }

    /// The first of each event in the window from `start` for `hours`, more than 0 and at
    /// most 48. An event that doesn't happen in the window is nil.
    public static func events(latitude: Double, longitude: Double, start: Date, hours: Double = 24) throws(Failure) -> Events {
        guard (-90...90).contains(latitude), (-180...180).contains(longitude), hours > 0, hours <= 48 else { throw .outOfRange }
        let jd0 = julianDay(start), jd1 = jd0 + hours / 24
        let step = 5.0 / 1440

        func first(_ f: (Double) -> Double, rising: Bool) -> Date? {
            var t = jd0, a = f(t)
            while t < jd1 {
                let next = min(t + step, jd1), b = f(next)
                if rising ? (a < 0 && b >= 0) : (a >= 0 && b < 0) {
                    var lo = t, hi = next
                    for _ in 0..<30 {
                        let mid = (lo + hi) / 2
                        if (f(mid) >= 0) == rising { hi = mid } else { lo = mid }
                    }
                    let found = (lo + hi) / 2
                    return found < jd1 ? date(julianDay: found) : nil
                }
                t = next
                a = b
            }
            return nil
        }

        func altitude(_ jd: Double) -> Double { place(latitude: latitude, longitude: longitude, julianDay: jd).altitude }
        func above(_ level: Double) -> (Double) -> Double { { altitude($0) - level } }
        // The hour angle through 0, going from east of the meridian to west.
        let transit = first({ jd in
            let h = place(latitude: latitude, longitude: longitude, julianDay: jd).hourAngle
            return h > 180 ? h - 360 : h
        }, rising: true)

        var e = Events(isAlwaysUp: false, isAlwaysDown: false)
        e.rise = first(above(riseAltitude), rising: true)
        e.set = first(above(riseAltitude), rising: false)
        e.transit = transit
        e.civilDawn = first(above(-6), rising: true)
        e.civilDusk = first(above(-6), rising: false)
        e.nauticalDawn = first(above(-12), rising: true)
        e.nauticalDusk = first(above(-12), rising: false)
        e.astronomicalDawn = first(above(-18), rising: true)
        e.astronomicalDusk = first(above(-18), rising: false)
        if e.rise == nil && e.set == nil {
            let up = altitude(jd0) > riseAltitude
            e.isAlwaysUp = up
            e.isAlwaysDown = !up
        }
        return e
    }

    // MARK: - The sun's place

    private struct Place {
        var azimuth: Double
        var altitude: Double
        /// Degrees west of the meridian, 0 to 360.
        var hourAngle: Double
    }

    private static func place(latitude: Double, longitude: Double, julianDay jd: Double) -> Place {
        let (ra, dec, nutationInLongitude, epsilon) = apparent(julianDay: jd)

        // Apparent sidereal time (Meeus 12.4 plus the equation of the equinoxes), in UT.
        let tu = (jd - 2451545) / 36525
        let gmst = 280.46061837 + 360.98564736629 * (jd - 2451545) + 0.000387933 * tu * tu - tu * tu * tu / 38710000
        let gast = gmst + nutationInLongitude * cos(epsilon)
        let hourAngle = wrapped(gast + longitude - ra)

        let h = radians(hourAngle), phi = radians(latitude)
        let x = -cos(h) * cos(dec) * sin(phi) + sin(dec) * cos(phi)
        let y = -sin(h) * cos(dec)
        let z = cos(h) * cos(dec) * cos(phi) + sin(dec) * sin(phi)
        return Place(azimuth: wrapped(degrees(atan2(y, x))), altitude: degrees(atan2(z, (x * x + y * y).squareRoot())),
                     hourAngle: hourAngle)
    }

    /// The sun's apparent right ascension (degrees) and declination (radians), with the
    /// nutation in longitude (degrees) and true obliquity (radians): Meeus chapter 25's
    /// higher-accuracy method, on VSOP87D truncated to amplitudes of 1e-7.
    private static func apparent(julianDay jd: Double) -> (Double, Double, Double, Double) {
        // Dynamical time; ΔT near 69 s is well inside the tolerances.
        let jde = jd + 69.0 / 86400
        let t = (jde - 2451545) / 36525, tau = t / 10
        func sum(_ series: [[(Double, Double, Double)]]) -> Double {
            var total = 0.0, power = 1.0
            for terms in series {
                total += power * terms.reduce(0) { $0 + $1.0 * cos($1.1 + $1.2 * tau) }
                power *= tau
            }
            return total
        }
        let r = sum(vsopR)
        var lambda = degrees(sum(vsopL)) + 180
        let beta = -degrees(sum(vsopB))
        // To the FK5 system.
        let lambdaPrime = radians(lambda - 1.397 * t - 0.00031 * t * t)
        lambda -= 0.09033 / 3600
        let betaFK5 = beta + 0.03916 / 3600 * (cos(lambdaPrime) - sin(lambdaPrime))

        let omega = radians(125.04452 - 1934.136261 * t)
        let sunMean = radians(280.4665 + 36000.7698 * t), moonMean = radians(218.3165 + 481267.8813 * t)
        let nutationInLongitude = (-17.20 * sin(omega) - 1.32 * sin(2 * sunMean) - 0.23 * sin(2 * moonMean) + 0.21 * sin(2 * omega)) / 3600
        let nutationInObliquity = (9.20 * cos(omega) + 0.57 * cos(2 * sunMean) + 0.10 * cos(2 * moonMean) - 0.09 * cos(2 * omega)) / 3600
        lambda += nutationInLongitude - 20.4898 / 3600 / r

        let epsilon0 = 23.43929111 - (46.8150 * t + 0.00059 * t * t - 0.001813 * t * t * t) / 3600
        let epsilon = radians(epsilon0 + nutationInObliquity)
        let l = radians(lambda), b = radians(betaFK5)
        let ra = degrees(atan2(sin(l) * cos(epsilon) - tan(b) * sin(epsilon), cos(l)))
        let dec = asin(sin(b) * cos(epsilon) + cos(b) * sin(epsilon) * sin(l))
        return (ra, dec, nutationInLongitude, epsilon)
    }

    // MARK: - Helpers

    private static func julianDay(_ date: Date) -> Double { date.timeIntervalSince1970 / 86400 + 2440587.5 }
    private static func date(julianDay jd: Double) -> Date { Date(timeIntervalSince1970: (jd - 2440587.5) * 86400) }
    private static func radians(_ degrees: Double) -> Double { degrees * .pi / 180 }
    private static func degrees(_ radians: Double) -> Double { radians * 180 / .pi }

    private static func wrapped(_ degrees: Double) -> Double {
        let r = degrees.truncatingRemainder(dividingBy: 360)
        return r < 0 ? r + 360 : r
    }

    // MARK: - VSOP87D, the Earth

    /// VSOP87D L: terms A cos(B + C τ) for τ⁰ to τ⁵, amplitude ≥ 1e-7.
    private static let vsopL: [[(Double, Double, Double)]] = [
        [
            (1.75347045673, 0.0, 0.0),
            (0.03341656456, 4.66925680417, 6283.0758499914),
            (0.00034894275, 4.62610241759, 12566.1516999828),
            (3.417571e-05, 2.82886579606, 3.523118349),
            (3.497056e-05, 2.74411800971, 5753.3848848968),
            (3.135896e-05, 3.62767041758, 77713.7714681205),
            (2.676218e-05, 4.41808351397, 7860.4193924392),
            (2.342687e-05, 6.13516237631, 3930.2096962196),
            (1.273166e-05, 2.03709655772, 529.6909650946),
            (1.324292e-05, 0.74246356352, 11506.7697697936),
            (9.01855e-06, 2.04505443513, 26.2983197998),
            (1.199167e-05, 1.10962944315, 1577.3435424478),
            (8.57223e-06, 3.50849156957, 398.1490034082),
            (7.79786e-06, 1.17882652114, 5223.6939198022),
            (9.9025e-06, 5.23268129594, 5884.9268465832),
            (7.53141e-06, 2.53339053818, 5507.5532386674),
            (5.05264e-06, 4.58292563052, 18849.2275499742),
            (4.92379e-06, 4.20506639861, 775.522611324),
            (3.56655e-06, 2.91954116867, 0.0673103028),
            (2.84125e-06, 1.89869034186, 796.2980068164),
            (2.4281e-06, 0.34481140906, 5486.777843175),
            (3.17087e-06, 5.84901952218, 11790.6290886588),
            (2.71039e-06, 0.31488607649, 10977.078804699),
            (2.0616e-06, 4.80646606059, 2544.3144198834),
            (2.05385e-06, 1.86947813692, 5573.1428014331),
            (2.02261e-06, 2.45767795458, 6069.7767545534),
            (1.26184e-06, 1.0830263021, 20.7753954924),
            (1.55516e-06, 0.83306073807, 213.299095438),
            (1.15132e-06, 0.64544911683, 0.9803210682),
            (1.02851e-06, 0.63599846727, 4694.0029547076),
            (1.01724e-06, 4.26679821365, 7.1135470008),
            (9.9206e-07, 6.20992940258, 2146.1654164752),
            (1.32212e-06, 3.41118275555, 2942.4634232916),
            (9.7607e-07, 0.6810127227, 155.4203994342),
            (8.5128e-07, 1.29870743025, 6275.9623029906),
            (7.4651e-07, 1.75508916159, 5088.6288397668),
            (1.01895e-06, 0.97569221824, 15720.8387848784),
            (8.4711e-07, 3.67080093025, 71430.69561812909),
            (7.3547e-07, 4.67926565481, 801.8209311238),
            (7.3874e-07, 3.50319443167, 3154.6870848956),
            (7.8756e-07, 3.03698313141, 12036.4607348882),
            (7.9637e-07, 1.807913307, 17260.1546546904),
            (8.5803e-07, 5.98322631256, 161000.6857376741),
            (5.6963e-07, 2.78430398043, 6286.5989683404),
            (6.1148e-07, 1.81839811024, 7084.8967811152),
            (6.9627e-07, 0.83297596966, 9437.762934887),
            (5.6116e-07, 4.38694880779, 14143.4952424306),
            (6.2449e-07, 3.97763880587, 8827.3902698748),
            (5.1145e-07, 0.28306864501, 5856.4776591154),
            (5.5577e-07, 3.47006009062, 6279.5527316424),
            (4.1036e-07, 5.36817351402, 8429.2412664666),
            (5.1605e-07, 1.33282746983, 1748.016413067),
            (5.1992e-07, 0.18914945834, 12139.5535091068),
            (4.9e-07, 0.48735065033, 1194.4470102246),
            (3.92e-07, 6.16832995016, 10447.3878396044),
            (3.5566e-07, 1.77597314691, 6812.766815086),
            (3.677e-07, 6.04133859347, 10213.285546211),
            (3.6596e-07, 2.56955238628, 1059.3819301892),
            (3.3291e-07, 0.59309499459, 17789.845619785),
            (3.5954e-07, 1.70876111898, 2352.8661537718),
            (4.0938e-07, 2.39850881707, 19651.048481098),
            (3.0047e-07, 2.73975123935, 1349.8674096588),
            (3.0412e-07, 0.44294464135, 83996.84731811189),
            (2.3663e-07, 0.48473567763, 8031.0922630584),
            (2.3574e-07, 2.06527720049, 3340.6124266998),
            (2.1089e-07, 4.14825464101, 951.7184062506),
            (2.4738e-07, 0.21484762138, 3.5904286518),
            (2.5352e-07, 3.16470953405, 4690.4798363586),
            (2.282e-07, 5.22197888032, 4705.7323075436),
            (2.1419e-07, 1.42563735525, 16730.4636895958),
            (2.1891e-07, 5.55594302562, 553.5694028424),
            (1.7481e-07, 4.56052900359, 135.0650800354),
            (1.9925e-07, 5.22208471269, 12168.0026965746),
            (1.986e-07, 5.77470167653, 6309.3741697912),
            (2.03e-07, 0.37133792946, 283.8593188652),
            (1.4421e-07, 4.19315332546, 242.728603974),
            (1.6225e-07, 5.98837722564, 11769.8536931664),
            (1.5077e-07, 4.19567181073, 6256.7775301916),
            (1.9124e-07, 3.82219996949, 23581.2581773176),
            (1.8888e-07, 5.38626880969, 149854.4001348079),
            (1.4346e-07, 3.72355084422, 38.0276726358),
            (1.7898e-07, 2.21490735647, 13367.9726311066),
            (1.2054e-07, 2.62229588349, 955.5997416086),
            (1.1287e-07, 0.17739328092, 4164.311989613),
            (1.3971e-07, 4.40138139996, 6681.2248533996),
            (1.3621e-07, 1.88934471407, 7632.9432596502),
            (1.2503e-07, 1.13052412208, 5.5229243074),
            (1.0498e-07, 5.35909518669, 1592.5960136328),
            (1.0327e-07, 6.19982566125, 6438.4962494256),
            (1.2003e-07, 1.003514567, 632.7837393132),
            (1.0827e-07, 0.32734520222, 103.0927742186),
            (1.0005e-07, 6.0291496328, 5746.271337896),
            (1.0523e-07, 0.93871805506, 11926.2544136688)
        ],
        [
            (6283.31966747491, 0.0, 0.0),
            (0.00206058863, 2.67823455584, 6283.0758499914),
            (4.30343e-05, 2.63512650414, 12566.1516999828),
            (4.25264e-06, 1.59046980729, 3.523118349),
            (1.08977e-06, 2.96618001993, 1577.3435424478),
            (9.3478e-07, 2.59212835365, 18849.2275499742),
            (1.19261e-06, 5.79557487799, 26.2983197998),
            (7.2122e-07, 1.13846158196, 529.6909650946),
            (6.7768e-07, 1.87472304791, 398.1490034082),
            (6.7327e-07, 4.40918235168, 5507.5532386674),
            (5.9027e-07, 2.8879703846, 5223.6939198022),
            (5.5976e-07, 2.17471680261, 155.4203994342),
            (4.5407e-07, 0.39803079805, 796.2980068164),
            (3.6369e-07, 0.46624739835, 775.522611324),
            (2.8958e-07, 2.64707383882, 7.1135470008),
            (1.9097e-07, 1.84628332577, 5486.777843175),
            (2.0844e-07, 5.34138275149, 0.9803210682),
            (1.8508e-07, 4.96855124577, 213.299095438),
            (1.6233e-07, 0.03216483047, 2544.3144198834),
            (1.7293e-07, 2.99116864949, 6275.9623029906),
            (1.5832e-07, 1.43049285325, 2146.1654164752),
            (1.4615e-07, 1.20532366323, 10977.078804699),
            (1.1877e-07, 3.25804815607, 5088.6288397668),
            (1.1514e-07, 2.07502418155, 4694.0029547076),
            (1.2461e-07, 2.83432285512, 1748.016413067),
            (1.1808e-07, 5.2737979048, 1194.4470102246),
            (1.0641e-07, 0.76614199202, 553.5694028424)
        ],
        [
            (0.0005291887, 0.0, 0.0),
            (8.719837e-05, 1.07209665242, 6283.0758499914),
            (3.09125e-06, 0.86728818832, 12566.1516999828),
            (2.7339e-07, 0.05297871691, 3.523118349),
            (1.6334e-07, 5.18826691036, 26.2983197998),
            (1.5752e-07, 3.6845788943, 155.4203994342)
        ],
        [
            (2.89226e-06, 5.84384198723, 6283.0758499914),
            (3.4955e-07, 0.0, 0.0),
            (1.6819e-07, 5.48766912348, 12566.1516999828)
        ],
        [
            (1.14084e-06, 3.14159265359, 0.0)
        ],
        [],
    ]

    /// VSOP87D B: terms A cos(B + C τ) for τ⁰ to τ⁵, amplitude ≥ 1e-7.
    private static let vsopB: [[(Double, Double, Double)]] = [
        [
            (2.7962e-06, 3.19870156017, 84334.66158130829),
            (1.01643e-06, 5.42248619256, 5507.5532386674),
            (8.0445e-07, 3.88013204458, 5223.6939198022),
            (4.3806e-07, 3.70444689758, 2352.8661537718),
            (3.1933e-07, 4.00026369781, 1577.3435424478),
            (2.2724e-07, 3.9847383156, 1047.7473117547),
            (1.6392e-07, 3.56456119782, 5856.4776591154),
            (1.8141e-07, 4.98367470263, 6283.0758499914),
            (1.4443e-07, 3.70275614914, 9437.762934887),
            (1.4304e-07, 3.41117857525, 10213.285546211),
            (1.1246e-07, 4.8282069053, 14143.4952424306),
            (1.09e-07, 2.08574562327, 6812.766815086),
            (1.0367e-07, 4.05663927946, 71092.88135493269)
        ],
        [],
        [],
        [],
        [],
        [],
    ]

    /// VSOP87D R: terms A cos(B + C τ) for τ⁰ to τ⁵, amplitude ≥ 1e-7.
    private static let vsopR: [[(Double, Double, Double)]] = [
        [
            (1.00013988799, 0.0, 0.0),
            (0.01670699626, 3.09846350771, 6283.0758499914),
            (0.00013956023, 3.0552460962, 12566.1516999828),
            (3.08372e-05, 5.19846674381, 77713.7714681205),
            (1.628461e-05, 1.17387749012, 5753.3848848968),
            (1.575568e-05, 2.84685245825, 7860.4193924392),
            (9.24799e-06, 5.45292234084, 11506.7697697936),
            (5.42444e-06, 4.56409149777, 3930.2096962196),
            (4.7211e-06, 3.66100022149, 5884.9268465832),
            (3.2878e-06, 5.89983646482, 5223.6939198022),
            (3.45983e-06, 0.96368617687, 5507.5532386674),
            (3.06784e-06, 0.29867139512, 5573.1428014331),
            (1.74844e-06, 3.01193636534, 18849.2275499742),
            (2.43189e-06, 4.27349536153, 11790.6290886588),
            (2.11829e-06, 5.84714540314, 1577.3435424478),
            (1.85752e-06, 5.02194447178, 10977.078804699),
            (1.09835e-06, 5.05510636285, 5486.777843175),
            (9.8316e-07, 0.88681311277, 6069.7767545534),
            (8.6499e-07, 5.68959778254, 15720.8387848784),
            (8.5825e-07, 1.27083733351, 161000.6857376741),
            (6.2916e-07, 0.92177108832, 529.6909650946),
            (5.7056e-07, 2.01374292014, 83996.84731811189),
            (6.4903e-07, 0.27250613787, 17260.1546546904),
            (4.9384e-07, 3.24501240359, 2544.3144198834),
            (5.5736e-07, 5.24159798933, 71430.69561812909),
            (4.2515e-07, 6.01110242003, 6275.9623029906),
            (4.6963e-07, 2.57805070386, 775.522611324),
            (3.8968e-07, 5.36071738169, 4694.0029547076),
            (4.4661e-07, 5.53715807302, 9437.762934887),
            (3.566e-07, 1.67468058995, 12036.4607348882),
            (3.1921e-07, 0.18368229781, 5088.6288397668),
            (3.1846e-07, 1.77775642085, 398.1490034082),
            (3.3193e-07, 0.24370300098, 7084.8967811152),
            (3.8245e-07, 2.39255343974, 8827.3902698748),
            (2.8464e-07, 1.21344868176, 6286.5989683404),
            (3.749e-07, 0.82952922332, 19651.048481098),
            (3.6957e-07, 4.90107591914, 12139.5535091068),
            (3.4537e-07, 1.84270693282, 2942.4634232916),
            (2.6275e-07, 4.58896850401, 10447.3878396044),
            (2.4596e-07, 3.78660875483, 8429.2412664666),
            (2.3587e-07, 0.26866117066, 796.2980068164),
            (2.7793e-07, 1.89934330904, 6279.5527316424),
            (2.3927e-07, 4.99598548138, 5856.4776591154),
            (2.0349e-07, 4.65267995431, 2146.1654164752),
            (2.3287e-07, 2.80783650928, 14143.4952424306),
            (2.2103e-07, 1.95004702988, 3154.6870848956),
            (1.9506e-07, 5.38227371393, 2352.8661537718),
            (1.7958e-07, 0.19871379385, 6812.766815086),
            (1.7174e-07, 4.43315560735, 10213.285546211),
            (1.619e-07, 5.23160507859, 17789.845619785),
            (1.7314e-07, 6.15200787916, 16730.4636895958),
            (1.3814e-07, 5.18962074032, 8031.0922630584),
            (1.8833e-07, 0.67306674027, 149854.4001348079),
            (1.8331e-07, 2.25348733734, 23581.2581773176),
            (1.3641e-07, 3.68516118804, 4705.7323075436),
            (1.3139e-07, 0.65289581324, 13367.9726311066),
            (1.0414e-07, 4.33285688538, 11769.8536931664),
            (1.0169e-07, 1.59390681369, 4690.4798363586)
        ],
        [
            (0.00103018608, 1.10748969588, 6283.0758499914),
            (1.721238e-05, 1.06442301418, 12566.1516999828),
            (7.02215e-06, 3.14159265359, 0.0),
            (3.2346e-07, 1.02169059149, 18849.2275499742),
            (3.0799e-07, 2.84353804832, 5507.5532386674),
            (2.4971e-07, 1.31906709482, 5223.6939198022),
            (1.8485e-07, 1.42429748614, 1577.3435424478),
            (1.0078e-07, 5.91378194648, 10977.078804699)
        ],
        [
            (4.359385e-05, 5.78455133738, 6283.0758499914),
            (1.23633e-06, 5.57934722157, 12566.1516999828),
            (1.2341e-07, 3.14159265359, 0.0)
        ],
        [
            (1.44595e-06, 4.27319435148, 6283.0758499914)
        ],
        [],
        [],
    ]
}
