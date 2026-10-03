import Foundation

/// Read-only memory-mapped .npy (C order). Mapped pages are clean file pages, so
/// the 150 MB text-embedding table costs nothing until rows are touched.
final class NPY {
    let shape: [Int]
    let descr: String
    private let base: UnsafeRawPointer
    private let mapLen: Int
    private let mapBase: UnsafeMutableRawPointer
    let data: UnsafeRawPointer

    init(path: String) throws {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { throw QwenANEError.invalid("cannot open \(path)") }
        defer { close(fd) }
        var st = stat()
        fstat(fd, &st)
        mapLen = Int(st.st_size)
        guard let m = mmap(nil, mapLen, PROT_READ, MAP_PRIVATE, fd, 0), m != MAP_FAILED else {
            throw QwenANEError.invalid("mmap failed for \(path)")
        }
        mapBase = m
        base = UnsafeRawPointer(m)
        let b = base.assumingMemoryBound(to: UInt8.self)
        guard mapLen > 10, b[0] == 0x93, String(bytes: [b[1], b[2], b[3], b[4], b[5]], encoding: .ascii) == "NUMPY" else {
            throw QwenANEError.invalid("not an npy file: \(path)")
        }
        let major = b[6]
        var hlen = 0, off = 0
        if major == 1 { hlen = Int(b[8]) | Int(b[9]) << 8; off = 10 }
        else { hlen = Int(b[8]) | Int(b[9]) << 8 | Int(b[10]) << 16 | Int(b[11]) << 24; off = 12 }
        let header = String(decoding: UnsafeBufferPointer(start: b + off, count: hlen), as: UTF8.self)
        guard !header.contains("'fortran_order': True") else { throw QwenANEError.invalid("fortran order unsupported") }
        // descr
        guard let dr = header.range(of: "'descr': '") else { throw QwenANEError.invalid("npy header: no descr") }
        let rest = header[dr.upperBound...]
        descr = String(rest[..<rest.firstIndex(of: "'")!])
        // shape
        guard let sr = header.range(of: "'shape': (") else { throw QwenANEError.invalid("npy header: no shape") }
        let srest = header[sr.upperBound...]
        let inner = srest[..<srest.firstIndex(of: ")")!]
        shape = inner.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        data = base + off + hlen
    }

    var count: Int { shape.reduce(1, *) }
    var f32: UnsafePointer<Float> { precondition(descr == "<f4"); return data.assumingMemoryBound(to: Float.self) }
    var u32: UnsafePointer<UInt32> { precondition(descr == "<u4"); return data.assumingMemoryBound(to: UInt32.self) }
    var i32: UnsafePointer<Int32> { precondition(descr == "<i4"); return data.assumingMemoryBound(to: Int32.self) }
    var i64: UnsafePointer<Int64> { precondition(descr == "<i8"); return data.assumingMemoryBound(to: Int64.self) }

    deinit { munmap(mapBase, mapLen) }
}
