import XCTest
@testable import KestrelCore

final class FormatTests: XCTestCase {
    func testBytes() {
        XCTAssertEqual(Fmt.bytes(UInt64(512)), "512 B")
        XCTAssertEqual(Fmt.bytes(UInt64(1536)), "1.5 KB")
        XCTAssertEqual(Fmt.bytes(UInt64(5 * 1_073_741_824)), "5.0 GB")
        XCTAssertEqual(Fmt.bytes(UInt64(200 * 1_048_576)), "200 MB")
    }

    func testRates() {
        XCTAssertEqual(Fmt.rate(1_048_576, unit: .bytes), "1.0 MB/s")
        XCTAssertEqual(Fmt.rate(125_000, unit: .bits), "1.0 Mbps")
        XCTAssertEqual(Fmt.compactRate(0, unit: .bytes), "0B")
        XCTAssertEqual(Fmt.compactRate(1_200_000, unit: .bytes), "1.1M")
        XCTAssertEqual(Fmt.compactRate(30_000, unit: .bytes), "29K")
    }

    func testCPUScale() {
        XCTAssertEqual(Fmt.cpu(250, cores: 10, scale: .perCore), "250%")
        XCTAssertEqual(Fmt.cpu(250, cores: 10, scale: .perMac), "25%")
        XCTAssertEqual(Fmt.cpu(2.5, cores: 10, scale: .perCore), "2.5%")
    }

    func testTemperature() {
        XCTAssertEqual(Fmt.temp(50, unit: .celsius), "50°C")
        XCTAssertEqual(Fmt.temp(50, unit: .fahrenheit), "122°F")
        XCTAssertEqual(Fmt.temp(0, unit: .celsius), "–")
    }

    func testDurationAndTokens() {
        XCTAssertEqual(Fmt.duration(45), "45s")
        XCTAssertEqual(Fmt.duration(3 * 3600 + 120), "3h 2m")
        XCTAssertEqual(Fmt.duration(2 * 86400 + 3600), "2d 1h")
        XCTAssertEqual(Fmt.tokens(950), "950")
        XCTAssertEqual(Fmt.tokens(12_300), "12.3K")
        XCTAssertEqual(Fmt.tokens(4_500_000), "4.5M")
    }

    func testCTupleString() {
        let t: (CChar, CChar, CChar, CChar) = (104, 105, 0, 120)
        XCTAssertEqual(String(cTuple: t), "hi")
    }
}
