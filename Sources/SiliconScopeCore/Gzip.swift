//
//  File:      Gzip.swift
//  Created:   2026-10-05
//  Updated:   2026-10-05
//  Developer: Kennt Kim / Calida Lab
//  Overview:  gzip (RFC 1952) encoding for the Mac fleet agent's HTTP responses. A MachineMetrics
//             JSON is ~7 KB and compresses several-fold, and it is sent every 3 s for as long as a
//             viewer watches (#71). URLSession advertises and transparently decodes gzip, so the
//             viewer needs nothing; an agent only compresses when the request asks for it.
//  Notes:     Apple's Compression framework emits raw DEFLATE (RFC 1951) for COMPRESSION_ZLIB, so
//             the gzip member is assembled here: a 10-byte header, the DEFLATE stream, then CRC-32
//             and the input length mod 2^32, both little-endian. CRC-32 is the IEEE polynomial
//             (reflected 0xEDB88320), table-driven.
//
import Foundation
import Compression

public enum Gzip {
    /// The gzip member for `data`, or nil if compression failed (send it uncompressed then).
    public static func encode(_ data: Data) -> Data? {
        guard let deflated = deflate(data) else { return nil }
        var out = Data([0x1f, 0x8b, 0x08, 0x00,    // magic, CM = deflate, FLG = none
                        0x00, 0x00, 0x00, 0x00,    // MTIME = none
                        0x00, 0xff])               // XFL, OS = unknown
        out.append(deflated)
        appendLE32(&out, crc32(data))
        appendLE32(&out, UInt32(truncatingIfNeeded: data.count))
        return out
    }

    /// Whether an HTTP request's Accept-Encoding allows gzip (a "gzip;q=0" refusal excluded).
    public static func accepted(byAcceptEncoding header: String?) -> Bool {
        guard let header else { return false }
        for part in header.lowercased().split(separator: ",") {
            let fields = part.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            guard fields.first == "gzip" || fields.first == "*" else { continue }
            let refused = fields.dropFirst().contains { $0.replacingOccurrences(of: " ", with: "") == "q=0" }
            return !refused
        }
        return false
    }

    static func deflate(_ data: Data) -> Data? {
        if data.isEmpty { return Data([0x03, 0x00]) }               // an empty final block
        // DEFLATE never grows input by more than a few bytes per 64 KB block.
        let capacity = data.count + data.count / 16 + 64
        var out = Data(count: capacity)
        let written = out.withUnsafeMutableBytes { dst in
            data.withUnsafeBytes { src in
                compression_encode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, capacity,
                                          src.bindMemory(to: UInt8.self).baseAddress!, data.count,
                                          nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { return nil }
        out.count = written
        return out
    }

    private static let crcTable: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for byte in data { c = crcTable[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }

    private static func appendLE32(_ d: inout Data, _ v: UInt32) {
        d.append(contentsOf: [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF),
                              UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)])
    }
}
