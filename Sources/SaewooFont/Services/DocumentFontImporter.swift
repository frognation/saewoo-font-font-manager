import AppKit
import Foundation

/// One font face referenced by an external design document.
///
/// Figma usually provides PostScript name + family/style. Illustrator's
/// ExtendScript DOM provides the same via TextFont.name/family/style.
struct DocumentFontReference: Hashable, Identifiable, Sendable {
    let postScriptName: String?
    let familyName: String?
    let styleName: String?

    var id: String {
        [
            Self.identityPart(postScriptName),
            Self.identityPart(familyName),
            Self.identityPart(styleName)
        ].joined(separator: "::")
    }

    var displayName: String {
        if let familyName, let styleName {
            if let postScriptName, postScriptName != familyName {
                return "\(familyName) \(styleName) (\(postScriptName))"
            }
            return "\(familyName) \(styleName)"
        }
        if let postScriptName { return postScriptName }
        if let familyName { return familyName }
        return "Unknown font"
    }

    var shortName: String {
        if let familyName, let styleName { return "\(familyName) \(styleName)" }
        return postScriptName ?? familyName ?? "Unknown font"
    }

    var isEmpty: Bool {
        postScriptName == nil && familyName == nil
    }

    init(postScriptName: String?, familyName: String?, styleName: String?) {
        self.postScriptName = Self.cleaned(postScriptName)
        self.familyName = Self.cleaned(familyName)
        self.styleName = Self.cleaned(styleName)
    }

    private static func cleaned(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let cleaned = raw
            .replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    private static func identityPart(_ raw: String?) -> String {
        cleaned(raw)?.folding(options: [.caseInsensitive, .diacriticInsensitive],
                              locale: .current)
            .lowercased() ?? ""
    }
}

struct DocumentFontScan: Sendable {
    let sourceName: String
    let references: [DocumentFontReference]
}

enum DocumentFontImportError: LocalizedError {
    case illustratorNotRunning
    case noOpenIllustratorDocument
    case appleScriptCouldNotCompile
    case appleScriptFailed(String)
    case invalidFigmaInput
    case missingFigmaToken
    case figmaHTTPStatus(Int, String)
    case invalidFigmaResponse
    case noFontsFound(String)

    var errorDescription: String? {
        switch self {
        case .illustratorNotRunning:
            return "Adobe Illustrator is not running."
        case .noOpenIllustratorDocument:
            return "No Illustrator document is open."
        case .appleScriptCouldNotCompile:
            return "Could not compile the Illustrator automation script."
        case .appleScriptFailed(let message):
            return message
        case .invalidFigmaInput:
            return "Enter a valid Figma file URL or file key."
        case .missingFigmaToken:
            return "Enter a Figma personal access token."
        case .figmaHTTPStatus(let status, let message):
            return "Figma returned HTTP \(status): \(message)"
        case .invalidFigmaResponse:
            return "Figma returned an unreadable file response."
        case .noFontsFound(let source):
            return "No text fonts were found in \(source)."
        }
    }
}

enum DocumentFontImporter {
    // MARK: - Illustrator

    static func scanIllustratorActiveDocument() async throws -> DocumentFontScan {
        try await Task.detached(priority: .userInitiated) {
            guard !NSRunningApplication
                    .runningApplications(withBundleIdentifier: "com.adobe.illustrator")
                    .isEmpty else {
                throw DocumentFontImportError.illustratorNotRunning
            }

            let source = """
            tell application id "com.adobe.illustrator"
                if not (exists document 1) then error "No Illustrator document is open."
                set fontReport to do javascript \(appleScriptStringLiteral(illustratorFontScanJavaScript))
            end tell
            return fontReport
            """

            guard let script = NSAppleScript(source: source) else {
                throw DocumentFontImportError.appleScriptCouldNotCompile
            }

            var errorInfo: NSDictionary?
            let result = script.executeAndReturnError(&errorInfo)
            if let errorInfo {
                let message = (errorInfo[NSAppleScript.errorMessage] as? String)
                    ?? "Illustrator automation failed."
                if message.localizedCaseInsensitiveContains("No Illustrator document") {
                    throw DocumentFontImportError.noOpenIllustratorDocument
                }
                throw DocumentFontImportError.appleScriptFailed(message)
            }

            guard let output = result.stringValue else {
                throw DocumentFontImportError.noFontsFound("Illustrator")
            }
            return try parseTabSeparatedReport(output, sourcePrefix: "Illustrator")
        }.value
    }

    /// ExtendScript runs inside Illustrator and returns:
    /// first line = document name, following lines = psName<TAB>family<TAB>style.
    private static let illustratorFontScanJavaScript = """
    (function(){var TAB=String.fromCharCode(9),LF=String.fromCharCode(10);if(app.documents.length===0){throw new Error('No Illustrator document is open.');}var doc=app.activeDocument,seen={};function clean(value){if(value===undefined||value===null){return '';}return String(value).replace(/[\\r\\n\\t]+/g,' ').replace(/^\\s+|\\s+$/g,'');}function addFont(font){if(!font){return;}var ps=clean(font.name),family=clean(font.family),style=clean(font.style);if(!ps&&!family){return;}seen[ps+TAB+family+TAB+style]=true;}function scanRange(range){try{addFont(range.characterAttributes.textFont);}catch(e){}try{var chars=range.characters;for(var i=0;i<chars.length;i++){try{addFont(chars[i].characterAttributes.textFont);}catch(e2){}}}catch(e3){}}for(var t=0;t<doc.textFrames.length;t++){try{scanRange(doc.textFrames[t].textRange);}catch(e4){}}var fonts=[];for(var key in seen){if(seen.hasOwnProperty(key)){fonts.push(key);}}fonts.sort();return clean(doc.name)+LF+fonts.join(LF);})()
    """

    private static func appleScriptStringLiteral(_ value: String) -> String {
        let compact = value.replacingOccurrences(of: "\n", with: " ")
        let escaped = compact
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    // MARK: - Figma

    static func scanFigmaFile(fileInput: String, token: String) async throws -> DocumentFontScan {
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedToken.isEmpty else { throw DocumentFontImportError.missingFigmaToken }

        let fileKey = try figmaFileKey(from: fileInput)
        let url = URL(string: "https://api.figma.com/v1/files/\(fileKey)")!
        var request = URLRequest(url: url)
        request.setValue(trimmedToken, forHTTPHeaderField: "X-Figma-Token")
        request.setValue("SaewooFont/1.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw DocumentFontImportError.invalidFigmaResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = figmaErrorMessage(from: data) ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            throw DocumentFontImportError.figmaHTTPStatus(http.statusCode, message)
        }

        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DocumentFontImportError.invalidFigmaResponse
        }

        let fileName = (root["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let sourceName = fileName?.isEmpty == false ? "Figma: \(fileName!)" : "Figma: \(fileKey)"
        var references = Set<DocumentFontReference>()

        if let document = root["document"] as? [String: Any] {
            collectFigmaFonts(in: document, into: &references)
        } else {
            collectFigmaFonts(in: root, into: &references)
        }

        let sorted = references
            .filter { !$0.isEmpty }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }

        guard !sorted.isEmpty else {
            throw DocumentFontImportError.noFontsFound(sourceName)
        }

        return DocumentFontScan(sourceName: sourceName, references: sorted)
    }

    static func figmaFileKey(from input: String) throws -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw DocumentFontImportError.invalidFigmaInput }

        if let url = URL(string: trimmed), let host = url.host, host.contains("figma.com") {
            let parts = url.path.split(separator: "/").map(String.init)
            for marker in ["file", "design", "proto", "board"] {
                if let index = parts.firstIndex(of: marker), parts.indices.contains(index + 1) {
                    return parts[index + 1]
                }
            }
            throw DocumentFontImportError.invalidFigmaInput
        }

        if trimmed.range(of: #"^[A-Za-z0-9_-]{8,}$"#, options: .regularExpression) != nil {
            return trimmed
        }

        throw DocumentFontImportError.invalidFigmaInput
    }

    private static func figmaErrorMessage(from data: Data) -> String? {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return (json["message"] as? String)
            ?? (json["err"] as? String)
            ?? (json["error"] as? String)
    }

    private static func collectFigmaFonts(in node: [String: Any],
                                          into references: inout Set<DocumentFontReference>) {
        if (node["type"] as? String) == "TEXT" {
            let baseStyle = node["style"] as? [String: Any] ?? [:]
            addFigmaStyle(baseStyle, into: &references)

            if let overrideTable = node["styleOverrideTable"] as? [String: Any] {
                for value in overrideTable.values {
                    guard let overrideStyle = value as? [String: Any] else { continue }
                    var merged = baseStyle
                    for (key, value) in overrideStyle { merged[key] = value }
                    addFigmaStyle(merged, into: &references)
                }
            }
        }

        if let children = node["children"] as? [[String: Any]] {
            for child in children {
                collectFigmaFonts(in: child, into: &references)
            }
        }
    }

    private static func addFigmaStyle(_ style: [String: Any],
                                      into references: inout Set<DocumentFontReference>) {
        let ref = DocumentFontReference(
            postScriptName: style["fontPostScriptName"] as? String,
            familyName: style["fontFamily"] as? String,
            styleName: style["fontStyle"] as? String
        )
        if !ref.isEmpty { references.insert(ref) }
    }

    // MARK: - Shared parsing

    private static func parseTabSeparatedReport(_ output: String,
                                                sourcePrefix: String) throws -> DocumentFontScan {
        let lines = output
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard let documentName = lines.first else {
            throw DocumentFontImportError.noFontsFound(sourcePrefix)
        }

        let references = Set(lines.dropFirst().compactMap { line -> DocumentFontReference? in
            let parts = line.components(separatedBy: "\t")
            let ref = DocumentFontReference(
                postScriptName: parts.indices.contains(0) ? parts[0] : nil,
                familyName: parts.indices.contains(1) ? parts[1] : nil,
                styleName: parts.indices.contains(2) ? parts[2] : nil
            )
            return ref.isEmpty ? nil : ref
        })

        let sorted = references
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        let sourceName = "\(sourcePrefix): \(documentName)"

        guard !sorted.isEmpty else {
            throw DocumentFontImportError.noFontsFound(sourceName)
        }

        return DocumentFontScan(sourceName: sourceName, references: sorted)
    }
}
