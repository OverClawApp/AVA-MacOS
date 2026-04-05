import Foundation
import os

/// Indexes local codebases for AI agent context.
/// Extracts file structure, symbols, and language info.
final class CodebaseIndexer {
    static let shared = CodebaseIndexer()

    private let logger = Logger(subsystem: Constants.bundleID, category: "CodebaseIndexer")
    private let fm = FileManager.default
    private let supportDir: String = {
        let dir = NSHomeDirectory() + "/Library/Application Support/AVA-Desktop/indexes"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }()

    // In-memory index cache
    private var indexes: [String: ProjectIndex] = [:]

    // MARK: - Types

    struct ProjectIndex: Codable {
        let path: String
        let indexedAt: Date
        var files: [FileEntry]
    }

    struct FileEntry: Codable {
        let path: String
        let relativePath: String
        let language: String?
        let size: Int
        var symbols: [Symbol]
    }

    struct Symbol: Codable {
        let name: String
        let type: String // "function", "class", "struct", "enum", "protocol", "variable", "import"
        let line: Int
    }

    struct SearchResult {
        let file: String
        let symbol: String
        let type: String
        let line: Int
        let score: Double
    }

    struct ProjectSummary {
        let path: String
        let fileCount: Int
        let lastIndexed: Date
    }

    // MARK: - Index

    func indexProject(at path: String) async throws -> ProjectIndex {
        logger.info("Indexing project at \(path)")

        var files: [FileEntry] = []
        let skipDirs: Set<String> = [".git", "node_modules", ".build", "DerivedData", "Pods", ".next", "dist", "build", "__pycache__", ".venv", "venv"]
        let codeExtensions: Set<String> = ["swift", "ts", "tsx", "js", "jsx", "py", "rs", "go", "java", "kt", "rb", "php", "c", "cpp", "h", "hpp", "cs", "m", "mm", "sql", "sh", "yaml", "yml", "json", "toml", "md"]

        let enumerator = fm.enumerator(atPath: path)
        while let relativePath = enumerator?.nextObject() as? String {
            // Skip hidden/vendor directories
            let components = relativePath.components(separatedBy: "/")
            if components.contains(where: { skipDirs.contains($0) || $0.hasPrefix(".") }) {
                continue
            }

            let fullPath = (path as NSString).appendingPathComponent(relativePath)
            let ext = (relativePath as NSString).pathExtension.lowercased()
            guard codeExtensions.contains(ext) else { continue }

            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: fullPath, isDirectory: &isDir), !isDir.boolValue else { continue }

            let attrs = try? fm.attributesOfItem(atPath: fullPath)
            let size = attrs?[.size] as? Int ?? 0

            // Skip large files
            guard size < 500_000 else { continue }

            let language = languageForExtension(ext)
            let symbols = extractSymbols(from: fullPath, language: language)

            files.append(FileEntry(
                path: fullPath,
                relativePath: relativePath,
                language: language,
                size: size,
                symbols: symbols
            ))
        }

        let index = ProjectIndex(path: path, indexedAt: Date(), files: files)
        indexes[path] = index

        // Persist
        let indexFile = supportDir + "/" + path.replacingOccurrences(of: "/", with: "_") + ".json"
        if let data = try? JSONEncoder().encode(index) {
            try? data.write(to: URL(fileURLWithPath: indexFile))
        }

        logger.info("Indexed \(files.count) files, \(files.reduce(0) { $0 + $1.symbols.count }) symbols")
        return index
    }

    // MARK: - Search

    func search(query: String, projectPath: String?) -> [SearchResult] {
        let queryLower = query.lowercased()
        var results: [SearchResult] = []

        let projectsToSearch: [ProjectIndex]
        if let path = projectPath, let idx = indexes[NSString(string: path).expandingTildeInPath] {
            projectsToSearch = [idx]
        } else {
            projectsToSearch = Array(indexes.values)
        }

        for index in projectsToSearch {
            for file in index.files {
                // Match file name
                if file.relativePath.lowercased().contains(queryLower) {
                    results.append(SearchResult(file: file.relativePath, symbol: file.relativePath, type: "file", line: 0, score: 0.8))
                }

                // Match symbols
                for symbol in file.symbols {
                    if symbol.name.lowercased().contains(queryLower) {
                        let score = symbol.name.lowercased() == queryLower ? 1.0 : 0.6
                        results.append(SearchResult(file: file.relativePath, symbol: symbol.name, type: symbol.type, line: symbol.line, score: score))
                    }
                }
            }
        }

        return results.sorted { $0.score > $1.score }
    }

    // MARK: - List

    func listIndexedProjects() -> [ProjectSummary] {
        indexes.values.map { idx in
            ProjectSummary(path: idx.path, fileCount: idx.files.count, lastIndexed: idx.indexedAt)
        }
    }

    // MARK: - Symbol Extraction (lightweight regex-based)

    private func extractSymbols(from path: String, language: String?) -> [Symbol] {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        var symbols: [Symbol] = []
        let lines = content.components(separatedBy: "\n")

        for (lineNum, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            switch language {
            case "swift":
                if let match = trimmed.firstMatch(of: /^(?:public |private |internal |open )?(?:static )?func\s+(\w+)/) {
                    symbols.append(Symbol(name: String(match.1), type: "function", line: lineNum + 1))
                } else if let match = trimmed.firstMatch(of: /^(?:public |private |internal |open )?(?:final )?class\s+(\w+)/) {
                    symbols.append(Symbol(name: String(match.1), type: "class", line: lineNum + 1))
                } else if let match = trimmed.firstMatch(of: /^(?:public |private |internal |open )?struct\s+(\w+)/) {
                    symbols.append(Symbol(name: String(match.1), type: "struct", line: lineNum + 1))
                } else if let match = trimmed.firstMatch(of: /^(?:public |private |internal |open )?protocol\s+(\w+)/) {
                    symbols.append(Symbol(name: String(match.1), type: "protocol", line: lineNum + 1))
                } else if let match = trimmed.firstMatch(of: /^(?:public |private |internal |open )?enum\s+(\w+)/) {
                    symbols.append(Symbol(name: String(match.1), type: "enum", line: lineNum + 1))
                }

            case "typescript", "javascript":
                if let match = trimmed.firstMatch(of: /^(?:export\s+)?(?:async\s+)?function\s+(\w+)/) {
                    symbols.append(Symbol(name: String(match.1), type: "function", line: lineNum + 1))
                } else if let match = trimmed.firstMatch(of: /^(?:export\s+)?class\s+(\w+)/) {
                    symbols.append(Symbol(name: String(match.1), type: "class", line: lineNum + 1))
                } else if let match = trimmed.firstMatch(of: /^(?:export\s+)?interface\s+(\w+)/) {
                    symbols.append(Symbol(name: String(match.1), type: "interface", line: lineNum + 1))
                } else if let match = trimmed.firstMatch(of: /^(?:export\s+)?(?:const|let|var)\s+(\w+)\s*=\s*(?:async\s+)?\(/) {
                    symbols.append(Symbol(name: String(match.1), type: "function", line: lineNum + 1))
                }

            case "python":
                if let match = trimmed.firstMatch(of: /^(?:async\s+)?def\s+(\w+)/) {
                    symbols.append(Symbol(name: String(match.1), type: "function", line: lineNum + 1))
                } else if let match = trimmed.firstMatch(of: /^class\s+(\w+)/) {
                    symbols.append(Symbol(name: String(match.1), type: "class", line: lineNum + 1))
                }

            case "rust":
                if let match = trimmed.firstMatch(of: /^(?:pub\s+)?(?:async\s+)?fn\s+(\w+)/) {
                    symbols.append(Symbol(name: String(match.1), type: "function", line: lineNum + 1))
                } else if let match = trimmed.firstMatch(of: /^(?:pub\s+)?struct\s+(\w+)/) {
                    symbols.append(Symbol(name: String(match.1), type: "struct", line: lineNum + 1))
                } else if let match = trimmed.firstMatch(of: /^(?:pub\s+)?enum\s+(\w+)/) {
                    symbols.append(Symbol(name: String(match.1), type: "enum", line: lineNum + 1))
                } else if let match = trimmed.firstMatch(of: /^(?:pub\s+)?trait\s+(\w+)/) {
                    symbols.append(Symbol(name: String(match.1), type: "trait", line: lineNum + 1))
                }

            case "go":
                if let match = trimmed.firstMatch(of: /^func\s+(?:\(\w+\s+\*?\w+\)\s+)?(\w+)/) {
                    symbols.append(Symbol(name: String(match.1), type: "function", line: lineNum + 1))
                } else if let match = trimmed.firstMatch(of: /^type\s+(\w+)\s+struct/) {
                    symbols.append(Symbol(name: String(match.1), type: "struct", line: lineNum + 1))
                } else if let match = trimmed.firstMatch(of: /^type\s+(\w+)\s+interface/) {
                    symbols.append(Symbol(name: String(match.1), type: "interface", line: lineNum + 1))
                }

            default:
                break
            }
        }

        return symbols
    }

    private func languageForExtension(_ ext: String) -> String? {
        let map: [String: String] = [
            "swift": "swift", "ts": "typescript", "tsx": "typescript",
            "js": "javascript", "jsx": "javascript", "py": "python",
            "rs": "rust", "go": "go", "java": "java", "kt": "kotlin",
            "rb": "ruby", "php": "php", "c": "c", "cpp": "cpp",
            "h": "c", "hpp": "cpp", "cs": "csharp", "m": "objc",
            "sql": "sql", "sh": "shell", "yaml": "yaml", "yml": "yaml",
            "json": "json", "toml": "toml", "md": "markdown",
        ]
        return map[ext]
    }
}
