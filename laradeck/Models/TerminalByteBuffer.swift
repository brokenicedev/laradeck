import Foundation
import Observation

/// A reference type so `TerminalOutputView`'s coordinator can tell "this data" apart from
/// "different data" via object identity, regardless of what's feeding it (a running process's PTY
/// output, or a tailed log file).
@MainActor
protocol TerminalBufferSource: AnyObject {
    var terminalData: Data { get }
    var terminalGeneration: Int { get }
}

/// Raw-byte accumulator behind a `TerminalOutputView`. Capped, and reset wholesale rather than
/// trimmed from the front when it overflows — partially trimming a byte stream risks cutting an
/// ANSI escape sequence in half.
@MainActor
@Observable
final class TerminalByteBuffer: TerminalBufferSource {
    private(set) var terminalData = Data()
    private(set) var terminalGeneration = 0
    private let maxBytes: Int

    init(maxBytes: Int = 512 * 1024) {
        self.maxBytes = maxBytes
    }

    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        if terminalData.count + data.count > maxBytes {
            terminalData.removeAll()
            terminalGeneration += 1
        }
        terminalData.append(data)
    }

    /// Normalizes plain log streams (e.g. `docker compose logs`) for SwiftTerm rendering.
    func appendLogStream(_ data: Data) {
        append(Self.normalizeForTerminal(data))
    }

    func appendText(_ text: String) {
        append(Data((text + "\r\n").utf8))
    }

    func clear() {
        terminalData.removeAll()
        terminalGeneration += 1
    }

    /// Inserts `\r` before lone `\n` bytes so line-oriented logs wrap like PTY output in SwiftTerm.
    static func normalizeForTerminal(_ data: Data) -> Data {
        guard !data.isEmpty else { return data }
        var result = Data()
        result.reserveCapacity(data.count + data.count / 8)
        var previous: UInt8 = 0
        for byte in data {
            if byte == 0x0A, previous != 0x0D {
                result.append(0x0D)
            }
            result.append(byte)
            previous = byte
        }
        return result
    }
}
