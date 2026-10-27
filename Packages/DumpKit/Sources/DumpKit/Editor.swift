import Foundation

/// Editors offered in settings ("Code editor"). It first tries the editor's URL scheme,
/// then falls back to its command-line binary; we do the same.
public enum Editor: String, CaseIterable, Identifiable {
    case vscode, vscodeInsiders, cursor, phpstorm, idea, sublime, zed, textmate, macvim, emacs, custom

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .vscode: return "VS Code"
        case .vscodeInsiders: return "VS Code Insiders"
        case .cursor: return "Cursor"
        case .phpstorm: return "PhpStorm"
        case .idea: return "IntelliJ IDEA"
        case .sublime: return "Sublime Text"
        case .zed: return "Zed"
        case .textmate: return "TextMate"
        case .macvim: return "MacVim"
        case .emacs: return "Emacs"
        case .custom: return "Custom"
        }
    }

    /// URL template with `%path` and `%line`.
    public var urlTemplate: String? {
        switch self {
        case .vscode: return "vscode://file/%path:%line"
        case .vscodeInsiders: return "vscode-insiders://file/%path:%line"
        case .cursor: return "cursor://file/%path:%line"
        case .phpstorm: return "phpstorm://open?file=%path&line=%line"
        case .idea: return "idea://open?file=%path&line=%line"
        case .sublime: return "subl://open?url=file://%path&line=%line"
        case .zed: return "zed://file/%path:%line"
        case .textmate: return "txmt://open?url=file://%path&line=%line"
        case .macvim: return "mvim://open?url=file://%path&line=%line"
        case .emacs: return "emacs://open?url=file://%path&line=%line"
        case .custom: return nil
        }
    }

    /// CLI fallback: binary name and arguments with `%path` / `%line`.
    public var binary: (name: String, args: [String])? {
        switch self {
        case .vscode: return ("code", ["--goto", "%path:%line"])
        case .vscodeInsiders: return ("code-insiders", ["--goto", "%path:%line"])
        case .cursor: return ("cursor", ["--goto", "%path:%line"])
        case .phpstorm: return ("phpstorm", ["--line", "%line", "%path"])
        case .idea: return ("idea", ["--line", "%line", "%path"])
        case .sublime: return ("subl", ["%path:%line"])
        case .zed: return ("zed", ["%path:%line"])
        case .textmate: return ("mate", ["--line", "%line", "%path"])
        case .macvim: return ("mvim", ["+%line", "%path"])
        case .emacs: return ("emacsclient", ["-n", "+%line", "%path"])
        case .custom: return nil
        }
    }

    public static func fill(_ template: String, path: String, line: Int, encodePath: Bool) -> String {
        let p = encodePath ? (path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path) : path
        return template.replacingOccurrences(of: "%path", with: p).replacingOccurrences(of: "%line", with: String(line))
    }

    public func url(path: String, line: Int, customTemplate: String = "") -> URL? {
        let template = self == .custom ? customTemplate : (urlTemplate ?? "")
        guard !template.isEmpty else { return nil }
        return URL(string: Editor.fill(template, path: path, line: line, encodePath: true))
    }
}
