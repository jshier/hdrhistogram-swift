//
// Copyright (c) 2026 Ordo One AB.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
//
// You may obtain a copy of the License at
// http://www.apache.org/licenses/LICENSE-2.0
//

import Foundation
@testable import Histogram
import XCTest

final class HistogramCodableTests: XCTestCase {
    /// A histogram as package-benchmark makes them: values up to 10^9 at three digits (21,504 slots), auto-resizing.
    private static func makeHistogram() -> Histogram<UInt> {
        var histogram = Histogram<UInt>(highestTrackableValue: 1_000_000_000, numberOfSignificantValueDigits: .three)
        histogram.autoResize = true
        for value: UInt64 in [91_204_729, 91_205_113, 91_212_026, 98, 99, 99, 0, 1_234, 1_234, 4_000_000_000] {
            histogram.record(value)
        }
        return histogram
    }

    private static func encoded(_ histogram: Histogram<UInt>) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(histogram)
    }

    /// Just the encoded counts.
    private struct EncodedCounts: Decodable {
        let counts: [Int64]
    }

    /// The encoded counts, as JSON numbers.
    private static func encodedCounts(_ data: Data) throws -> [Int64] {
        try JSONDecoder().decode(EncodedCounts.self, from: data).counts
    }

    /// `data` with its counts replaced by `counts`.
    private static func replacingCounts(in data: Data, with counts: [Int64]) throws -> Data {
        try replacing(["counts": counts.map { Int($0) }], in: data)
    }

    /// `data` with the properties in `values` replaced.
    private static func replacing(_ values: [String: Any], in data: Data) throws -> Data {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for (key, value) in values {
            object[key] = value
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    func testRoundTripKeepsEveryValue() throws {
        let histogram = Self.makeHistogram()
        let decoded = try JSONDecoder().decode(Histogram<UInt>.self, from: Self.encoded(histogram))

        XCTAssertEqual(decoded, histogram)
        XCTAssertEqual(decoded.counts, histogram.counts)
        XCTAssertEqual(decoded.totalCount, histogram.totalCount)
        XCTAssertEqual(decoded.min, histogram.min)
        XCTAssertEqual(decoded.max, histogram.max)
        XCTAssertEqual(decoded.mean, histogram.mean)
        XCTAssertEqual(decoded.stdDeviation, histogram.stdDeviation)
        XCTAssertEqual(decoded.highestTrackableValue, histogram.highestTrackableValue)
        XCTAssertEqual(decoded.autoResize, histogram.autoResize)
        for percentile in [0.0, 25.0, 50.0, 75.0, 90.0, 99.0, 99.9, 100.0] {
            XCTAssertEqual(decoded.valueAtPercentile(percentile), histogram.valueAtPercentile(percentile))
        }
    }

    func testCountsAreRunLengthEncoded() throws {
        let histogram = Self.makeHistogram()
        let counts = try Self.encodedCounts(Self.encoded(histogram))

        // Five distinct recorded slots, at most one zero run around each: 11 entries, against tens of thousands of slots.
        let nonZeroSlots = histogram.counts.filter { $0 != 0 }.count
        XCTAssertEqual(counts.filter { $0 > 0 }.count, nonZeroSlots)
        XCTAssertLessThanOrEqual(counts.count, 2 * nonZeroSlots + 1)
        XCTAssertEqual(counts.reduce(Int64(0)) { $0 + ($1 < 0 ? -$1 : 1) }, Int64(histogram.counts.count))
        // No two runs of zeros in a row, and no empty run.
        XCTAssertFalse(counts.contains(0))
        XCTAssertFalse(zip(counts, counts.dropFirst()).contains { $0 < 0 && $1 < 0 })
    }

    func testDecodesTheDenseForm() throws {
        // Counts written one per slot, as by versions before the run-length encoding.
        let histogram = Self.makeHistogram()
        let dense = try Self.replacingCounts(in: Self.encoded(histogram), with: histogram.counts.map { Int64($0) })
        let decoded = try JSONDecoder().decode(Histogram<UInt>.self, from: dense)

        XCTAssertEqual(decoded, histogram)
        XCTAssertEqual(decoded.counts, histogram.counts)
    }

    func testEmptyHistogramRoundTrips() throws {
        let histogram = Histogram<UInt64>(highestTrackableValue: 3_600_000_000, numberOfSignificantValueDigits: .two)
        let data = try JSONEncoder().encode(histogram)
        let decoded = try JSONDecoder().decode(Histogram<UInt64>.self, from: data)

        XCTAssertEqual(decoded, histogram)
        XCTAssertEqual(decoded.counts, histogram.counts)
        XCTAssertEqual(try Self.encodedCounts(data), [-Int64(histogram.counts.count)])
    }

    func testSortedKeysMakeTheEncodingStable() throws {
        // With `.sortedKeys` the same histogram always encodes to the same bytes, including after a round trip.
        let histogram = Self.makeHistogram()
        let first = try Self.encoded(histogram)
        let decoded = try JSONDecoder().decode(Histogram<UInt>.self, from: first)

        XCTAssertEqual(try Self.encoded(histogram), first)
        XCTAssertEqual(try Self.encoded(decoded), first)
    }

    func testRejectsMalformedCounts() throws {
        let histogram = Self.makeHistogram()
        let data = try Self.encoded(histogram)
        let length = Int64(histogram.counts.count)
        let malformed: [[Int64]] = [
            [-(length - 1)], // one count short
            [-length, 1], // one count too many
            [-(length + 1)], // a run past the end
            [Int64.min], // a run far past the end
            [-(length - 1), -1, 1] // a run past the end after others
        ]
        for counts in malformed {
            let bad = try Self.replacingCounts(in: data, with: counts)
            XCTAssertThrowsError(try JSONDecoder().decode(Histogram<UInt>.self, from: bad), "\(counts)") { error in
                guard case DecodingError.dataCorrupted = error else {
                    return XCTFail("Expected dataCorrupted for \(counts), got \(error)")
                }
            }
        }
    }

    func testRejectsCountsOutOfRangeForTheCountType() throws {
        let histogram = Histogram<UInt8>(highestTrackableValue: 1_000, numberOfSignificantValueDigits: .two)
        let data = try JSONEncoder().encode(histogram)
        let length = Int64(histogram.counts.count)
        let tooLarge = try Self.replacingCounts(in: data, with: [256, -(length - 1)])

        XCTAssertThrowsError(try JSONDecoder().decode(Histogram<UInt8>.self, from: tooLarge))
    }

    func testRejectsLayoutsThePrecisionCantHave() throws {
        // A few bytes asking for an impossible or enormous counts array: refused before anything is allocated (a bucket
        // count of Int.max overflowed the length; a large sub-bucket magnitude asked for exabytes of zeros).
        let data = try Self.encoded(Self.makeHistogram())
        let layouts: [[String: Any]] = [
            ["bucketCount": 0, "counts": [-1_024]],
            ["bucketCount": 65, "counts": [-1]],
            ["bucketCount": Int.max, "counts": [-1]],
            ["bucketCount": -2, "counts": [-1]],
            ["subBucketHalfCountMagnitude": 40, "counts": [Int64.min + 1]],
            ["subBucketHalfCountMagnitude": 9, "counts": [-1]],
            ["unitMagnitude": 60, "counts": [-1]]
        ]
        for layout in layouts {
            let bad = try Self.replacing(layout, in: data)
            XCTAssertThrowsError(try JSONDecoder().decode(Histogram<UInt>.self, from: bad), "\(layout)") { error in
                guard case DecodingError.dataCorrupted = error else {
                    return XCTFail("Expected dataCorrupted for \(layout), got \(error)")
                }
            }
        }
    }

    func testNegativeCountsDontEncode() throws {
        // A signed count type allows a negative count, which would read back as a run of zeros.
        var histogram = Histogram<Int64>(highestTrackableValue: 1_000, numberOfSignificantValueDigits: .two)
        histogram.record(10)
        histogram.counts[histogram.countsIndexForValue(10)] = -3
        XCTAssertThrowsError(try JSONEncoder().encode(histogram)) { error in
            guard case EncodingError.invalidValue = error else {
                return XCTFail("Expected invalidValue, got \(error)")
            }
        }
    }
}
