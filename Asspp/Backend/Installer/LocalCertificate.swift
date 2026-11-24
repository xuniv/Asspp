import Foundation

/// DER for the two certificates issued by Asspp's offline installer.
enum LocalCertificate {
    static func issue(
        name: String, issuer: String, publicKey: Data, serial: Data,
        from start: Date, until end: Date, host: String?,
        sign: (Data) throws -> Data
    ) rethrows -> Data {
        let algorithm = sequence(oid([0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 1, 1, 11]), tagged(5, Data()))
        let rsa = sequence(oid([0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 1, 1, 1]), tagged(5, Data()))
        let constraints = extensionValue(19, critical: true, value: host == nil ? sequence(tagged(1, Data([255]))) : sequence())
        let usage = extensionValue(15, critical: true, value: tagged(3, host == nil ? Data([1, 0x06]) : Data([5, 0xa0])))
        var extensions = constraints + usage
        if let host {
            extensions += extensionValue(17, value: sequence(tagged(0x82, Data(host.utf8))))
            extensions += extensionValue(37, value: sequence(oid([0x2b, 6, 1, 5, 5, 7, 3, 1])))
        }
        var serial = Data(serial.drop(while: { $0 == 0 }))
        if serial.isEmpty { serial.append(1) }
        if serial[0] >= 128 { serial.insert(0, at: 0) }
        let body = sequence(
            tagged(0xa0, tagged(2, Data([2]))), tagged(2, serial),
            algorithm, distinguishedName(issuer), sequence(time(start), time(end)),
            distinguishedName(name), sequence(rsa, bitString(publicKey)),
            tagged(0xa3, tagged(0x30, extensions)),
        )
        return sequence(body, algorithm, bitString(try sign(body)))
    }

    static func pem(_ data: Data, label: String) -> Data {
        let body = data.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        return Data("-----BEGIN \(label)-----\n\(body)\n-----END \(label)-----\n".utf8)
    }

    private static func distinguishedName(_ name: String) -> Data {
        sequence(tagged(0x31, sequence(oid([0x55, 4, 3]), tagged(0x0c, Data(name.utf8)))))
    }

    private static func time(_ value: Date) -> Data {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMddHHmmss'Z'"
        let text = formatter.string(from: value)
        if text.hasPrefix("20") && text.prefix(4) < "2050" {
            return tagged(0x17, Data(text.dropFirst(2).utf8))
        }
        return tagged(0x18, Data(text.utf8))
    }

    private static func extensionValue(_ id: UInt8, critical: Bool = false, value: Data) -> Data {
        sequence(oid([0x55, 0x1d, id]), critical ? tagged(1, Data([255])) : Data(), tagged(4, value))
    }

    private static func bitString(_ data: Data) -> Data { tagged(3, Data([0]) + data) }
    private static func oid(_ bytes: [UInt8]) -> Data { tagged(6, Data(bytes)) }
    private static func sequence(_ items: Data...) -> Data { tagged(0x30, items.reduce(into: Data()) { $0.append($1) }) }

    private static func tagged(_ tag: UInt8, _ data: Data) -> Data {
        if data.count < 128 { return Data([tag, UInt8(data.count)]) + data }
        var length = data.count
        var bytes: [UInt8] = []
        while length > 0 {
            bytes.insert(UInt8(truncatingIfNeeded: length), at: 0)
            length >>= 8
        }
        return Data([tag, UInt8(0x80 + bytes.count)] + bytes) + data
    }
}
