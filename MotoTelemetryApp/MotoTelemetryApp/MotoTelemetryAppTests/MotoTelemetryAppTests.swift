//
//  MotoTelemetryAppTests.swift
//  MotoTelemetryAppTests
//
//  Created by vinothiniraju on 2026-08-26.
//

import XCTest
@testable import MotoTelemetryApp

final class MotoTelemetryAppTests: XCTestCase {

    @MainActor
    func testMinimumDurationDefaultsAndPersistence() throws {
        let defaults = UserDefaults.standard
        let previous = defaults.data(forKey: "RiderPreferences")
        defer {
            if let previous { defaults.set(previous, forKey: "RiderPreferences") }
            else { defaults.removeObject(forKey: "RiderPreferences") }
        }
        defaults.removeObject(forKey: "RiderPreferences")
        let preferences = RiderPreferences()
        XCTAssertTrue(preferences.minimumDurationEnabled)
        XCTAssertEqual(preferences.effectiveMinimumDuration, 0.5)
        preferences.minimumWheelieDuration = 0.25
        preferences.minimumDurationEnabled = false
        let restored = RiderPreferences()
        XCTAssertEqual(restored.effectiveMinimumDuration, 0)
        restored.minimumDurationEnabled = true
        XCTAssertEqual(restored.effectiveMinimumDuration, 0.25)

        // Older installs keep their other settings and receive the new 0.5 s default.
        let data = try XCTUnwrap(defaults.data(forKey: "RiderPreferences"))
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy.removeValue(forKey: "minimumDurationEnabled")
        legacy.removeValue(forKey: "minimumWheelieDuration")
        defaults.set(try JSONSerialization.data(withJSONObject: legacy), forKey: "RiderPreferences")
        XCTAssertEqual(RiderPreferences().effectiveMinimumDuration, 0.5)
    }

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    func testExample() throws {
        // This is an example of a functional test case.
        // Use XCTAssert and related functions to verify your tests produce the correct results.
        // Any test you write for XCTest can be annotated as throws and async.
        // Mark your test throws to produce an unexpected failure when your test encounters an uncaught error.
        // Mark your test async to allow awaiting for asynchronous code to complete. Check the results with assertions afterwards.
    }

    func testPerformanceExample() throws {
        // This is an example of a performance test case.
        self.measure {
            // Put the code you want to measure the time of here.
        }
    }

}
