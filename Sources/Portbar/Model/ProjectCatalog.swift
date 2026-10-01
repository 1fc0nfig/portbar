import AppKit
import Foundation

/// A runnable script of a project: a `package.json` script or a custom command.
struct ProjectScript: Identifiable, Hashable {
    var id: String { name }
    let name: String
    /// What the script does, for the tooltip (`next dev --turbopack`).
    let detail: String
    /// The shell command portbar runs (`bun run dev`).
    let command: String
    let isCustom: Bool
}

/// Reads project metadata from disk: scripts and icons. Caches results for 30 seconds.
@MainActor
final class ProjectCatalog {
    private var scriptCache: [String: (at: Date, scripts: [ProjectScript])] = [:]
    private var iconCache: [String: NSImage?] = [:]

    // MARK: Scripts

    /// `package.json` scripts of `directory`, run with the package manager its lockfile names.
    func packageScripts(in directory: String) -> [ProjectScript] {
        if let cached = scriptCache[directory], Date().timeIntervalSince(cached.at) < 30 { return cached.scripts }
        let scripts = Self.readPackageScripts(directory)
        scriptCache[directory] = (Date(), scripts)
        return scripts
    }

    func scripts(in directory: String, config: ProjectConfig?) -> [ProjectScript] {
        let custom = (config?.customScripts ?? []).map {
            ProjectScript(name: $0.name, detail: $0.command, command: $0.command, isCustom: true)
        }
        return custom + packageScripts(in: directory)
    }

    func favorites(in directory: String, config: ProjectConfig?) -> [ProjectScript] {
        let all = scripts(in: directory, config: config)
        let names = config?.favoriteScripts ?? ["dev"]
        return names.compactMap { name in all.first { $0.name == name } }
    }

    private static func readPackageScripts(_ directory: String) -> [ProjectScript] {
        let file = (directory as NSString).appendingPathComponent("package.json")
        guard let data = FileManager.default.contents(atPath: file),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let scripts = json["scripts"] as? [String: String] else { return [] }
        let runner = packageManager(directory, packageManagerField: json["packageManager"] as? String)
        let preferredOrder = ["dev", "start", "build", "test", "lint", "typecheck", "preview"]
        return scripts.keys.sorted { a, b in
            let ia = preferredOrder.firstIndex(of: a) ?? Int.max
            let ib = preferredOrder.firstIndex(of: b) ?? Int.max
            return ia != ib ? ia < ib : a < b
        }.map { name in
            ProjectScript(name: name, detail: scripts[name] ?? "", command: "\(runner) run \(name)", isCustom: false)
        }
    }

    private static func packageManager(_ directory: String, packageManagerField: String?) -> String {
        if let field = packageManagerField?.split(separator: "@").first { return String(field) }
        let fm = FileManager.default
        func has(_ f: String) -> Bool { fm.fileExists(atPath: (directory as NSString).appendingPathComponent(f)) }
        if has("bun.lock") || has("bun.lockb") { return "bun" }
        if has("pnpm-lock.yaml") { return "pnpm" }
        if has("yarn.lock") { return "yarn" }
        return "npm"
    }

    // MARK: Discovery

    private var discovered: (at: Date, roots: [String], projects: [String])?

    /// Project folders inside the roots, one level deep. Cached for 60 seconds.
    func discover(roots: [String]) -> [String] {
        if let d = discovered, d.roots == roots, Date().timeIntervalSince(d.at) < 60 { return d.projects }
        let projects = Self.scan(roots)
        discovered = (Date(), roots, projects)
        return projects
    }

    func invalidateDiscovery() { discovered = nil }

    private static let markers = [".git", "package.json", "Cargo.toml", "go.mod", "pyproject.toml", "Gemfile",
                                  "composer.json", "deno.json", "Makefile", "docker-compose.yml", "compose.yaml",
                                  "Package.swift", "pubspec.yaml", "mix.exs"]

    static func scan(_ roots: [String]) -> [String] {
        let fm = FileManager.default
        var found: [String] = []
        for root in Settings.uniqueFolders(roots) {
            guard let children = try? fm.contentsOfDirectory(atPath: root) else { continue }
            for name in children where !name.hasPrefix(".") && name != "node_modules" {
                let dir = (root as NSString).appendingPathComponent(name)
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else { continue }
                if markers.contains(where: { fm.fileExists(atPath: (dir as NSString).appendingPathComponent($0)) }) {
                    found.append(dir)
                }
            }
        }
        return found.sorted {
            ($0 as NSString).lastPathComponent.localizedCaseInsensitiveCompare(($1 as NSString).lastPathComponent) == .orderedAscending
        }
    }

    // MARK: Frameworks

    private var frameworkCache: [String: [ServiceKind]] = [:]

    /// Frameworks found in the project files, most specific first. Cached until `invalidateIcons()`.
    func frameworks(in root: String) -> [ServiceKind] {
        if let cached = frameworkCache[root] { return cached }
        let found = Self.detectFrameworks(root)
        frameworkCache[root] = found
        return found
    }

    /// Package names and the kind they mean, in priority order: app frameworks before bundlers and runtimes.
    private static let jsFrameworks: [(String, ServiceKind)] = [
        ("expo", .tool("expo", "Expo", brand: "expo")),
        ("react-native", .tool("expo", "React Native", brand: "react")),
        ("next", .tool("next", "Next.js", brand: "nextdotjs")),
        ("nuxt", .tool("nuxt", "Nuxt", brand: "nuxt")),
        ("astro", .tool("astro", "Astro", brand: "astro")),
        ("@remix-run/react", .tool("remix", "Remix", brand: "remix")),
        ("@sveltejs/kit", .tool("sveltekit", "SvelteKit", brand: "svelte")),
        ("@angular/core", .tool("angular", "Angular", brand: "angular")),
        ("electron", .tool("electron", "Electron", brand: "electron")),
        ("@tauri-apps/api", .tool("tauri", "Tauri", brand: "tauri")),
        ("vue", .tool("vue", "Vue", brand: "vuedotjs")),
        ("svelte", .tool("svelte", "Svelte", brand: "svelte")),
        ("hono", .tool("hono", "Hono", brand: "hono")),
        ("convex", .tool("convex", "Convex", brand: "convex")),
        ("vite", .tool("vite", "Vite", brand: "vite")),
        ("react", .tool("react", "React", brand: "react")),
    ]

    static func detectFrameworks(_ root: String) -> [ServiceKind] {
        let fm = FileManager.default
        var js: [(rank: Int, kind: ServiceKind)] = []
        var other: [ServiceKind] = []

        for dir in candidateDirs(root) {
            func has(_ f: String) -> Bool { fm.fileExists(atPath: (dir as NSString).appendingPathComponent(f)) }
            func text(_ f: String) -> String {
                (try? String(contentsOfFile: (dir as NSString).appendingPathComponent(f), encoding: .utf8)) ?? ""
            }
            if let data = fm.contents(atPath: (dir as NSString).appendingPathComponent("package.json")),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let deps = Set(((json["dependencies"] as? [String: Any]) ?? [:]).keys)
                    .union(((json["devDependencies"] as? [String: Any]) ?? [:]).keys)
                if let i = jsFrameworks.firstIndex(where: { deps.contains($0.0) }) {
                    js.append((i, jsFrameworks[i].1))
                }
            }
            if has("pubspec.yaml") { other.append(.tool("flutter", "Flutter", brand: "flutter")) }
            if has("Package.swift") || ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).contains(where: { $0.hasSuffix(".xcodeproj") }) {
                other.append(.tool("swift", "Swift", brand: "swift"))
            }
            if has("Cargo.toml") { other.append(.tool("rust", "Rust", brand: "rust")) }
            if has("go.mod") { other.append(.tool("go", "Go", brand: "go")) }
            if has("pyproject.toml") || has("requirements.txt") {
                let t = (text("pyproject.toml") + text("requirements.txt")).lowercased()
                if t.contains("django") { other.append(.tool("django", "Django", brand: "django")) }
                else if t.contains("fastapi") { other.append(.tool("fastapi", "FastAPI", brand: "fastapi")) }
                else if t.contains("flask") { other.append(.tool("flask", "Flask", brand: "flask")) }
                else { other.append(.runtime("python", "Python", brand: "python")) }
            }
            if has("Gemfile") { other.append(.tool("rails", "Ruby", brand: "rubyonrails")) }
            if has("composer.json") { other.append(.tool("php", "PHP", brand: "php")) }
            if has("mix.exs") { other.append(.tool("phoenix", "Elixir", brand: "elixir")) }
            if has("build.gradle.kts") || has("build.gradle") { other.append(.tool("kotlin", "Kotlin", brand: "kotlin")) }
            if has("deno.json") { other.append(.runtime("deno", "Deno", brand: "deno")) }
            if has("docker-compose.yml") || has("compose.yaml") { other.append(.tool("docker", "Docker", brand: "docker")) }
        }

        var result: [ServiceKind] = []
        for kind in js.sorted(by: { $0.rank < $1.rank }).map(\.kind) + other where !result.contains(where: { $0.id == kind.id }) {
            result.append(kind)
        }
        return result
    }

    // MARK: Last modified

    private var modifiedCache: [String: (at: Date, value: Date)] = [:]

    /// Latest of: git activity (index, HEAD, reflog) and package.json. Cached for 30 seconds.
    func lastModified(_ path: String) -> Date {
        if let c = modifiedCache[path], Date().timeIntervalSince(c.at) < 30 { return c.value }
        let fm = FileManager.default
        let files = [".git/index", ".git/HEAD", ".git/logs/HEAD", ".git/FETCH_HEAD", ".git",
                     "package.json", "Cargo.toml", "pyproject.toml", "go.mod"]
        let dates = files.compactMap { name -> Date? in
            let file = (path as NSString).appendingPathComponent(name)
            return (try? fm.attributesOfItem(atPath: file))?[.modificationDate] as? Date
        }
        let value = dates.max() ?? .distantPast
        modifiedCache[path] = (Date(), value)
        return value
    }

    func sorted(_ paths: [String], by sort: ProjectSort, name: (String) -> String) -> [String] {
        switch sort {
        case .name:
            return paths.sorted { name($0).localizedCaseInsensitiveCompare(name($1)) == .orderedAscending }
        case .modified:
            return paths.sorted { lastModified($0) > lastModified($1) }
        }
    }

    // MARK: Icons

    func icon(for config: ProjectConfig?, repoRoot: String) -> NSImage? {
        switch config?.iconMode ?? .auto {
        case .none, .framework:
            return nil
        case .custom:
            guard let path = config?.customIconPath else { return nil }
            return cachedImage(path)
        case .auto:
            if let cached = iconCache[repoRoot] { return cached }
            let found = Self.findIcon(in: repoRoot).flatMap { cachedImage($0) }
            iconCache[repoRoot] = .some(found)
            return found
        }
    }

    /// Forget cached icons, for example after the user picks a new file.
    func invalidateIcons() { iconCache.removeAll(); frameworkCache.removeAll() }

    private func cachedImage(_ path: String) -> NSImage? {
        if let cached = iconCache["file:" + path] { return cached }
        let image = NSImage(contentsOfFile: path)
        iconCache["file:" + path] = .some(image)
        return image
    }

    private static let skipDirs: Set = ["node_modules", "ios", "android", "build", "dist", "out", "target", "vendor",
                                        "docs", "doc", "scripts", "test", "tests", "coverage", "tmp", "lib", "bin"]

    /// Folders that may hold an app: the root, its direct subfolders, and `apps/*`, `packages/*`. Root first.
    static func candidateDirs(_ root: String) -> [String] {
        let fm = FileManager.default
        var dirs = [root]
        func children(_ dir: String) -> [String] {
            ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).sorted()
                .filter { !$0.hasPrefix(".") && !skipDirs.contains($0.lowercased()) }
                .map { (dir as NSString).appendingPathComponent($0) }
                .filter { var d: ObjCBool = false; return fm.fileExists(atPath: $0, isDirectory: &d) && d.boolValue }
        }
        for child in children(root).prefix(40) {
            let name = (child as NSString).lastPathComponent
            if name == "apps" || name == "packages" {
                dirs += children(child).prefix(12)
            } else {
                dirs.append(child)
            }
        }
        return dirs
    }

    /// Best-looking icon in the repository. Larger raster icons win over `favicon.ico`.
    static func findIcon(in root: String) -> String? {
        let fm = FileManager.default
        // In order of preference: app icons first, then favicons.
        let names = [
            "apple-touch-icon.png", "apple-icon.png", "icon.png", "app_logo.png", "app-icon.png",
            "android-chrome-512x512.png", "icon-512x512.png", "android-chrome-192x192.png", "icon-192x192.png",
            "logo.png", "logo512.png", "logo192.png", "favicon.png", "icon.svg", "logo.svg", "favicon.svg",
            "favicon.ico", "icon.icns",
        ]
        let subdirs = ["public", "public/img", "public/images", "public/icons", "app", "src/app", "static",
                       "assets", "assets/images", "assets/icon", "assets/icons", "src/assets", "resources", ""]

        let roots = candidateDirs(root)

        // Expo: app.json → expo.icon
        for r in roots {
            let appJSON = (r as NSString).appendingPathComponent("app.json")
            if let data = fm.contents(atPath: appJSON),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let expo = json["expo"] as? [String: Any], let icon = expo["icon"] as? String {
                let path = ((r as NSString).appendingPathComponent(icon) as NSString).standardizingPath
                if fm.fileExists(atPath: path) { return path }
            }
        }

        // Web app manifest: the largest icon it lists.
        for r in roots {
            for manifest in ["public/manifest.json", "public/site.webmanifest", "public/manifest.webmanifest",
                             "manifest.json", "static/manifest.json"] {
                let file = (r as NSString).appendingPathComponent(manifest)
                guard let data = fm.contents(atPath: file),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let icons = json["icons"] as? [[String: Any]] else { continue }
                func size(_ icon: [String: Any]) -> Int {
                    ((icon["sizes"] as? String) ?? "").split(separator: " ")
                        .compactMap { Int($0.split(separator: "x").first ?? "") }.max() ?? 0
                }
                let base = (file as NSString).deletingLastPathComponent
                for icon in icons.sorted(by: { size($0) > size($1) }) {
                    guard let src = icon["src"] as? String, !src.hasPrefix("http") else { continue }
                    let path = ((base as NSString).appendingPathComponent(src) as NSString).standardizingPath
                    if fm.fileExists(atPath: path) { return path }
                }
            }
        }

        for name in names {
            for r in roots {
                for sub in subdirs {
                    let path = ((r as NSString).appendingPathComponent(sub) as NSString).appendingPathComponent(name)
                    if fm.fileExists(atPath: path) { return path }
                }
            }
        }
        return nil
    }
}
