import XCTest
@testable import MotoTelemetryCore

final class TelemetryExportTests: XCTestCase {

    // MARK: - CSV Header

    func testCSVHeaderIsExactSpec() {
        // ui-spec §9.7 mandates this exact string. A typo here breaks every
        // downstream parser that keys on the header.
        XCTAssertEqual(TelemetryExport.csvHeader, "elapsed_seconds,angle_degrees,speed_kph")
    }

    func testCSVOutputStartsWithHeader() {
        let csv = TelemetryExport.exportCSV(points: [])
        XCTAssertEqual(csv, "elapsed_seconds,angle_degrees,speed_kph")
    }

    // MARK: - Unit Conversion: radians -> degrees

    func testRadiansToDegreesConversion() {
        let point = TelemetryExport.DataPoint(
            elapsedSeconds: 1.0,
            angleRadians: .pi / 4,  // 45 degrees
            speedMetersPerSecond: nil
        )
        let csv = TelemetryExport.exportCSV(points: [point])
        let lines = csv.split(separator: "\n")
        XCTAssertEqual(lines.count, 2)

        let fields = lines[1].split(separator: ",", omittingEmptySubsequences: false)
        XCTAssertEqual(fields.count, 3)

        // angle_degrees should be 45.0
        let angle = Double(fields[1])!
        XCTAssertEqual(angle, 45.0, accuracy: 1e-4)
    }

    // MARK: - Unit Conversion: m/s -> km/h

    func testMetersPerSecondToKmhConversion() {
        // 10 m/s = 36 km/h
        let point = TelemetryExport.DataPoint(
            elapsedSeconds: 2.5,
            angleRadians: 0.5,
            speedMetersPerSecond: 10.0
        )
        let csv = TelemetryExport.exportCSV(points: [point])
        let lines = csv.split(separator: "\n")
        let fields = lines[1].split(separator: ",", omittingEmptySubsequences: false)

        let speed = Double(fields[2])!
        XCTAssertEqual(speed, 36.0, accuracy: 1e-4)
    }

    // MARK: - Missing speed renders empty, NEVER zero

    func testMissingSpeedRendersAsEmptyField() {
        let point = TelemetryExport.DataPoint(
            elapsedSeconds: 1.0,
            angleRadians: 0.1,
            speedMetersPerSecond: nil  // GNSS unavailable
        )
        let csv = TelemetryExport.exportCSV(points: [point])
        let lines = csv.split(separator: "\n")
        let dataLine = String(lines[1])

        // The line must end with a comma (empty field after last comma).
        XCTAssertTrue(dataLine.hasSuffix(","),
                      "Missing speed must produce a trailing comma (empty field), got: \(dataLine)")

        // Split preserving empty subsequences to verify the field is truly empty.
        let fields = dataLine.split(separator: ",", omittingEmptySubsequences: false)
        XCTAssertEqual(fields.count, 3, "must have exactly 3 fields")
        XCTAssertEqual(fields[2], "", "missing speed must be empty string, not '0' or '0.0'")
    }

    func testMissingSpeedIsNeverZero() {
        // Defence against someone "fixing" the empty field to "0.0".
        let point = TelemetryExport.DataPoint(
            elapsedSeconds: 1.0,
            angleRadians: 0.3,
            speedMetersPerSecond: nil
        )
        let csv = TelemetryExport.exportCSV(points: [point])
        let lines = csv.split(separator: "\n")
        let fields = String(lines[1]).split(separator: ",", omittingEmptySubsequences: false)
        // The speed field must not parse as any number (including 0).
        XCTAssertNil(Double(String(fields[2])),
                     "nil speed must not become a parseable number — got '\(fields[2])'")
    }

    // MARK: - Zero speed IS valid (a real stop)

    func testZeroSpeedRendersAsZero() {
        // A real 0 m/s (bike stopped) must render as "0" not as empty.
        let point = TelemetryExport.DataPoint(
            elapsedSeconds: 1.0,
            angleRadians: 0.0,
            speedMetersPerSecond: 0.0
        )
        let csv = TelemetryExport.exportCSV(points: [point])
        let lines = csv.split(separator: "\n")
        let fields = String(lines[1]).split(separator: ",", omittingEmptySubsequences: false)
        let speed = Double(String(fields[2]))
        XCTAssertNotNil(speed, "zero speed must be present as a number")
        XCTAssertEqual(speed!, 0.0, accuracy: 1e-10)
    }

    // MARK: - Locale independence

    func testNoDecimalCommasInOutput() {
        // A decimal comma would corrupt CSV parsing. Verify with values that
        // would be formatted with commas in de_DE, fr_FR, etc.
        let points = [
            TelemetryExport.DataPoint(elapsedSeconds: 1.123456, angleRadians: 0.789012, speedMetersPerSecond: 12.345),
            TelemetryExport.DataPoint(elapsedSeconds: 99.9, angleRadians: 1.5, speedMetersPerSecond: nil),
        ]
        let csv = TelemetryExport.exportCSV(points: points)

        // Count commas per data line: must be exactly 2 (field separators only).
        let lines = csv.split(separator: "\n")
        for line in lines.dropFirst() {  // skip header
            let commaCount = line.filter { $0 == "," }.count
            XCTAssertEqual(commaCount, 2,
                           "Each data line must have exactly 2 commas (separators), got \(commaCount) in: \(line)")
        }
    }

    // MARK: - Round-trip: a value survives CSV export and re-parse

    func testValueRoundTrips() {
        let originalAngleRad = 0.6  // ~34.377 degrees
        let originalSpeed = 15.0    // m/s = 54 km/h

        let point = TelemetryExport.DataPoint(
            elapsedSeconds: 3.14159,
            angleRadians: originalAngleRad,
            speedMetersPerSecond: originalSpeed
        )
        let csv = TelemetryExport.exportCSV(points: [point])
        let lines = csv.split(separator: "\n")
        let fields = String(lines[1]).split(separator: ",", omittingEmptySubsequences: false)

        let parsedElapsed = Double(fields[0])!
        let parsedAngle = Double(fields[1])!
        let parsedSpeed = Double(fields[2])!

        // Elapsed should match to 6 decimal places (our format precision).
        XCTAssertEqual(parsedElapsed, 3.14159, accuracy: 1e-5)
        // Angle in degrees.
        XCTAssertEqual(parsedAngle, originalAngleRad * 180 / .pi, accuracy: 1e-4)
        // Speed in km/h.
        XCTAssertEqual(parsedSpeed, originalSpeed * 3.6, accuracy: 1e-4)
    }

    // MARK: - Multiple points

    func testMultiplePointsProduceCorrectLineCount() {
        var points: [TelemetryExport.DataPoint] = []
        for i in 0..<5 {
            let speed: Double? = i % 2 == 0 ? Double(i) : nil
            points.append(TelemetryExport.DataPoint(
                elapsedSeconds: Double(i) * 0.01,
                angleRadians: Double(i) * 0.1,
                speedMetersPerSecond: speed
            ))
        }
        let csv = TelemetryExport.exportCSV(points: points)
        let lines = csv.split(separator: "\n")
        XCTAssertEqual(lines.count, 6)  // header + 5 data lines
    }

    // MARK: - JSON Export

    func testJSONExportContainsAllFields() {
        let points = [
            TelemetryExport.DataPoint(elapsedSeconds: 1.0, angleRadians: .pi / 6, speedMetersPerSecond: 20.0),
            TelemetryExport.DataPoint(elapsedSeconds: 2.0, angleRadians: .pi / 3, speedMetersPerSecond: nil),
        ]
        let json = TelemetryExport.exportJSON(points: points)

        XCTAssertTrue(json.contains("elapsed_seconds"))
        XCTAssertTrue(json.contains("angle_degrees"))
        XCTAssertTrue(json.contains("speed_kph"))
    }

    func testJSONMissingSpeedIsNull() {
        let points = [
            TelemetryExport.DataPoint(elapsedSeconds: 1.0, angleRadians: 0.5, speedMetersPerSecond: nil),
        ]
        let json = TelemetryExport.exportJSON(points: points)

        // JSON null for missing speed, never 0.
        XCTAssertTrue(json.contains("null"), "nil speed must encode as JSON null, got: \(json)")
        XCTAssertFalse(json.contains("\"speed_kph\" : 0"),
                       "nil speed must not become 0 in JSON")
    }

    func testJSONRoundTrip() throws {
        let points = [
            TelemetryExport.DataPoint(elapsedSeconds: 1.5, angleRadians: 0.7854, speedMetersPerSecond: 25.0),
        ]
        let json = TelemetryExport.exportJSON(points: points)
        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode([TelemetryExport.JSONRecord].self, from: data)

        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0].elapsed_seconds, 1.5, accuracy: 1e-10)
        XCTAssertEqual(decoded[0].angle_degrees, 0.7854 * 180 / .pi, accuracy: 1e-4)
        XCTAssertEqual(decoded[0].speed_kph!, 25.0 * 3.6, accuracy: 1e-4)
    }

    // MARK: - formatDouble internal

    func testFormatDoubleUsesDecimalPoint() {
        let result = TelemetryExport.formatDouble(3.14159)
        XCTAssertTrue(result.contains("."), "must use decimal point")
        XCTAssertFalse(result.contains(","), "must not use decimal comma")
    }

    func testFormatDoubleStripsTrailingZeros() {
        let result = TelemetryExport.formatDouble(1.5)
        XCTAssertEqual(result, "1.5")
    }

    func testFormatDoubleKeepsAtLeastOneDecimal() {
        let result = TelemetryExport.formatDouble(42.0)
        XCTAssertEqual(result, "42.0", "integer values must keep one decimal digit")
    }
}
