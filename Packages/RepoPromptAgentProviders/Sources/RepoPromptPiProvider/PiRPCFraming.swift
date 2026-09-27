import Foundation

/// pi RPC wire helpers. RPC mode uses strict JSONL semantics: records are delimited by
/// LF (`\n`) only, and clients must accept an optional trailing CR by stripping it.
/// Generic line readers that also split on Unicode separators (U+2028/U+2029) are not
/// protocol-compliant because those characters are valid inside JSON strings.
public enum PiRPCWire {
    /// Encodes requests as compact single-line JSON terminated by `\n`.
    public static func encodeRequestLine(_ command: PiRPCCommand, id: String? = nil) throws -> Data {
        let object = command.requestObject(id: id)
        let encoder = JSONEncoder()
        let body = try encoder.encode(object)
        var line = body
        line.append(0x0A)
        return line
    }

    /// Decodes one complete stdout line into a JSON value. The trailing CR of a CRLF
    /// pair is stripped; embedded U+2028/U+2029 remain part of the payload.
    public static func decodeLine(_ data: Data) throws -> PiJSONValue {
        var payload = data
        if payload.last == 0x0D {
            payload.removeLast()
        }
        guard let text = String(data: payload, encoding: .utf8) else {
            throw PiProviderError.framing(detail: "stdout line is not valid UTF-8")
        }
        guard !text.isEmpty else {
            throw PiProviderError.framing(detail: "stdout line is empty")
        }
        let decoder = JSONDecoder()
        do {
            return try decoder.decode(PiJSONValue.self, from: Data(text.utf8))
        } catch {
            throw PiProviderError.framing(detail: "stdout line is not valid JSON: \(error.localizedDescription)")
        }
    }
}

/// Incremental strict-LF line accumulator for a pi RPC stdout stream.
///
/// Feed arbitrary `Data` chunks; complete lines (delimited only by `0x0A`) come back.
/// Call `finish()` at EOF to flush a non-empty trailing buffer that was not
/// newline-terminated.
public struct PiRPCLineAccumulator: Sendable {
    private var buffer = Data()

    public init() {}

    /// Appends a chunk and returns every complete line it produced (without the LF;
    /// a single trailing CR is stripped and blank lines are skipped).
    public mutating func append(_ chunk: Data) -> [Data] {
        buffer.append(chunk)
        var lines: [Data] = []
        while let index = buffer.firstIndex(of: 0x0A) {
            var line = Data(buffer[buffer.startIndex ..< index])
            buffer.removeSubrange(buffer.startIndex ... index)
            if line.last == 0x0D {
                line.removeLast()
            }
            if !line.isEmpty {
                lines.append(line)
            }
        }
        return lines
    }

    /// Flushes a non-empty unterminated remainder at EOF, if any.
    public mutating func finish() -> Data? {
        guard !buffer.isEmpty else { return nil }
        let remainder = buffer
        buffer.removeAll()
        return remainder
    }

    public var hasPartialLine: Bool {
        !buffer.isEmpty
    }
}
