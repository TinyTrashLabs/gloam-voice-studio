import XCTest
@testable import StudioKit

final class SupertonicStyleFileTests: XCTestCase {
    /// Build a SuperTonic style JSON with unit-norm rows (flat `data`), optionally
    /// with wrong dims / a broken row / a non-finite value / an extra unknown key.
    private func styleJSON(ttlDims: [Int] = [1, 50, 256],
                           dpDims: [Int] = [1, 8, 16],
                           breakUnitRows: Bool = false,
                           extraKey: Bool = false) -> Data {
        func tensor(_ dims: [Int]) -> [String: Any] {
            let rowLen = dims.last!
            let rows = dims.reduce(1, *) / rowLen
            var data: [Double] = []
            for _ in 0..<rows {
                var row = [Double](repeating: 0, count: rowLen)
                row[0] = breakUnitRows ? 3.0 : 1.0   // unit row = [1,0,0,...]; broken = L2 3
                data.append(contentsOf: row)
            }
            return ["dims": dims, "data": data]
        }
        var obj: [String: Any] = ["style_ttl": tensor(ttlDims), "style_dp": tensor(dpDims)]
        if extraKey { obj["metadata"] = ["note": "from Voice Builder"] }
        return try! JSONSerialization.data(withJSONObject: obj)
    }

    /// Raw JSON string builder — needed for the non-finite case, since
    /// JSONSerialization refuses to *write* infinity but a real file's `1e999`
    /// parses to +inf.
    private func rawStyleJSON(nonFinite: Bool) -> Data {
        func tensor(_ dims: [Int], bad: Bool) -> String {
            let rowLen = dims.last!, rows = dims.reduce(1, *) / rowLen
            var flat: [String] = []
            for r in 0..<rows {
                for i in 0..<rowLen {
                    flat.append(i != 0 ? "0.0" : (r == 0 && bad ? "1e999" : "1.0"))
                }
            }
            return "{\"dims\":[\(dims.map(String.init).joined(separator: ","))],\"data\":[\(flat.joined(separator: ","))]}"
        }
        let s = "{\"style_ttl\":\(tensor([1, 50, 256], bad: nonFinite)),\"style_dp\":\(tensor([1, 8, 16], bad: false))}"
        return Data(s.utf8)
    }

    func testValidatesGoodStyleAndToleratesUnknownKeys() throws {
        XCTAssertNoThrow(try SupertonicStyleFile.validate(styleJSON()))
        XCTAssertNoThrow(try SupertonicStyleFile.validate(styleJSON(extraKey: true)))
    }

    func testRejectsWrongDims() {
        XCTAssertThrowsError(try SupertonicStyleFile.validate(styleJSON(ttlDims: [1, 49, 256])))
        XCTAssertThrowsError(try SupertonicStyleFile.validate(styleJSON(dpDims: [1, 8, 15])))
    }

    func testRejectsNonUnitRows() {
        XCTAssertThrowsError(try SupertonicStyleFile.validate(styleJSON(breakUnitRows: true)))
    }

    func testRejectsNonFinite() {
        // sanity: the same builder with bad:false validates, so only 1e999 differs
        XCTAssertNoThrow(try SupertonicStyleFile.validate(rawStyleJSON(nonFinite: false)))
        XCTAssertThrowsError(try SupertonicStyleFile.validate(rawStyleJSON(nonFinite: true)))
    }

    func testRejectsNonJSON() {
        XCTAssertThrowsError(try SupertonicStyleFile.validate(Data("not json".utf8)))
    }
}
