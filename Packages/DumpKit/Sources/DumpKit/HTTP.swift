import Foundation

public struct HTTPRequest {
    public var method: String
    public var path: String
    public var query: [String: String]
    /// Header names are lowercased.
    public var headers: [String: String]
    public var body: Data

    public init(method: String, path: String, query: [String: String] = [:], headers: [String: String] = [:], body: Data = Data()) {
        self.method = method
        self.path = path
        self.query = query
        self.headers = headers
        self.body = body
    }
}

public struct HTTPResponse {
    public var status: Int
    public var headers: [(String, String)]
    public var body: Data

    public init(status: Int, headers: [(String, String)] = [], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    public static func json(_ value: JSONValue, status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status, headers: [("Content-Type", "application/json; charset=utf-8")], body: Data(value.serialized().utf8))
    }

    public static func text(_ text: String, status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status, headers: [("Content-Type", "text/plain; charset=utf-8")], body: Data(text.utf8))
    }

    public func serialized() -> Data {
        var head = "HTTP/1.1 \(status) \(HTTPResponse.reason(status))\r\n"
        var all = headers
        all.append(("Content-Length", String(body.count)))
        all.append(("Connection", "close"))
        // CORS headers are sent, so browser clients can post too.
        all.append(("Access-Control-Allow-Origin", "*"))
        all.append(("Access-Control-Allow-Headers", "*"))
        all.append(("Access-Control-Allow-Methods", "GET,HEAD,PUT,PATCH,POST,DELETE"))
        for (k, v) in all { head += "\(k): \(v)\r\n" }
        head += "\r\n"
        var data = Data(head.utf8)
        data.append(body)
        return data
    }

    static func reason(_ status: Int) -> String {
        switch status {
        case 100: return "Continue"
        case 200: return "OK"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 404: return "Not Found"
        case 413: return "Payload Too Large"
        default: return "Status"
        }
    }
}

public enum HTTPParseResult {
    case incomplete(expectsContinue: Bool)
    case complete(HTTPRequest)
    case invalid(String)
}

public enum HTTPParser {
    private static let headerEnd = Data("\r\n\r\n".utf8)

    public static func parse(_ data: Data) -> HTTPParseResult {
        guard let range = data.range(of: headerEnd) else {
            return data.count > 64 * 1024 ? .invalid("headers too large") : .incomplete(expectsContinue: false)
        }
        guard let head = String(data: data[data.startIndex..<range.lowerBound], encoding: .utf8)
            ?? String(data: data[data.startIndex..<range.lowerBound], encoding: .isoLatin1) else {
            return .invalid("unreadable headers")
        }
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines[0].split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return .invalid("bad request line") }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        let target = String(parts[1])
        let (path, query) = splitTarget(target)
        let bodyStart = range.upperBound
        let expectsContinue = headers["expect"]?.lowercased() == "100-continue"

        var body: Data
        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            switch decodeChunked(data[bodyStart...]) {
            case .some(let decoded): body = decoded
            case .none: return .incomplete(expectsContinue: expectsContinue)
            }
        } else {
            let length = Int(headers["content-length"] ?? "0") ?? 0
            guard length >= 0 else { return .invalid("bad content-length") }
            guard data.count - bodyStart >= length else { return .incomplete(expectsContinue: expectsContinue) }
            body = Data(data[bodyStart..<(bodyStart + length)])
        }
        return .complete(HTTPRequest(method: String(parts[0]).uppercased(), path: path, query: query, headers: headers, body: body))
    }

    static func splitTarget(_ target: String) -> (String, [String: String]) {
        let pieces = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let rawPath = String(pieces[0])
        let path = rawPath.removingPercentEncoding ?? rawPath
        var query: [String: String] = [:]
        if pieces.count > 1 {
            for pair in pieces[1].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let decode: (Substring) -> String = {
                    let s = $0.replacingOccurrences(of: "+", with: " ")
                    return s.removingPercentEncoding ?? s
                }
                query[decode(kv[0])] = kv.count > 1 ? decode(kv[1]) : ""
            }
        }
        return (path, query)
    }

    /// Returns nil until the final zero-length chunk has arrived.
    static func decodeChunked(_ data: Data.SubSequence) -> Data? {
        var out = Data()
        var i = data.startIndex
        let crlf = Data("\r\n".utf8)
        while true {
            guard let lineEnd = data.range(of: crlf, in: i..<data.endIndex) else { return nil }
            let sizeText = String(decoding: data[i..<lineEnd.lowerBound], as: UTF8.self)
                .split(separator: ";").first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
            guard let size = Int(sizeText, radix: 16) else { return nil }
            let chunkStart = lineEnd.upperBound
            if size == 0 { return out }
            guard data.endIndex - chunkStart >= size + 2 else { return nil }
            out.append(data[chunkStart..<(chunkStart + size)])
            i = chunkStart + size + 2
        }
    }
}
