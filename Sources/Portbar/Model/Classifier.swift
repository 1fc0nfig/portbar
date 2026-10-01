import Foundation

/// What a process is, from the point of view of a developer looking at the menu bar.
struct ServiceKind: Hashable {
    let id: String
    let name: String
    /// Simple Icons slug, or nil to use the SF Symbol fallback.
    let brand: String?
    /// SF Symbol used when there is no brand mark.
    let symbol: String
    /// The service answers HTTP on its ports, so an HTTP probe is meaningful.
    let speaksHTTP: Bool
    /// A specific tool (Vite, Next.js). Generic runtimes (plain node, bun) are not specific.
    let isSpecific: Bool

    static func tool(_ id: String, _ name: String, brand: String?, symbol: String = "shippingbox",
                     http: Bool = true) -> ServiceKind {
        ServiceKind(id: id, name: name, brand: brand, symbol: symbol, speaksHTTP: http, isSpecific: true)
    }
    static func runtime(_ id: String, _ name: String, brand: String?, symbol: String = "terminal") -> ServiceKind {
        ServiceKind(id: id, name: name, brand: brand, symbol: symbol, speaksHTTP: true, isSpecific: false)
    }

    static let unknown = ServiceKind.runtime("process", "Process", brand: nil)
}

enum ProcessRole {
    /// Does the real work: a dev server, a database, a watcher.
    case service
    /// Only starts other processes: `bun run`, `npm run`, `concurrently`, a shell.
    case wrapper
    /// A helper of a service: esbuild service, PostCSS worker, jest worker.
    case worker
}

struct Classification {
    let kind: ServiceKind
    let role: ProcessRole
}

enum Classifier {
    static func classify(_ p: RawProcess) -> Classification {
        let tokens = Tokens(p)

        // Workers first: they often contain tool names in their paths.
        if tokens.exeBase == "esbuild" || tokens.has("esbuild") && tokens.args.contains(where: { $0.hasPrefix("--service") }) {
            return .init(kind: .tool("esbuild", "esbuild", brand: "esbuild", http: false), role: .worker)
        }
        if tokens.argBases.contains(where: { $0 == "postcss.js" || $0 == "processChild.js" || $0.hasPrefix("jest-worker") })
            || tokens.joined.contains("jest-worker") || tokens.joined.contains("/workers/") || tokens.joined.contains("tsserver")
            || tokens.joined.contains("typingsInstaller") {
            return .init(kind: tokens.runtimeKind, role: .worker)
        }

        // Package managers and process runners never do the work themselves.
        if isManager(tokens) { return .init(kind: tokens.runtimeKind, role: .wrapper) }

        // Known tools.
        for rule in rules where rule.matches(tokens) {
            return .init(kind: rule.kind, role: .service)
        }

        // Wrappers.
        if isWrapper(tokens) { return .init(kind: tokens.runtimeKind, role: .wrapper) }

        return .init(kind: tokens.runtimeKind, role: .service)
    }

    private static let managers: Set = [
        "npm", "npx", "npm-cli.js", "npx-cli.js", "pnpm", "pnpm.cjs", "pnpx", "yarn", "yarn.js", "concurrently",
        "turbo", "nodemon", "cross-env", "dotenv", "env", "run-p", "run-s", "npm-run-all", "nx", "lerna", "wireit",
        "op", "doppler", "infisical", "mise", "direnv", "watchexec",
    ]

    private static func isManager(_ t: Tokens) -> Bool {
        if managers.contains(t.exeBase) || t.scriptBase.map(managers.contains) == true { return true }
        return t.jsPackages.first.map(managers.contains) == true
    }

    private static func isWrapper(_ t: Tokens) -> Bool {
        let shells: Set = ["sh", "bash", "zsh", "fish", "dash", "-zsh", "-bash", "login"]
        if shells.contains(t.exeBase) { return true }
        // `bun run dev`, `bun x ...`, `bunx`, `deno task`
        if t.exeBase == "bun" || t.exeBase == "bunx" {
            if let first = t.args.dropFirst().first(where: { !$0.hasPrefix("-") }),
               ["run", "x", "dev", "start"].contains(first) || t.exeBase == "bunx" { return true }
        }
        if t.exeBase == "deno", t.args.dropFirst().first == "task" { return true }
        if t.exeBase == "uv" || t.exeBase == "poetry" || t.exeBase == "pipenv" { return true }
        return false
    }

    // MARK: - Rules

    private struct Rule {
        let kind: ServiceKind
        let matches: (Tokens) -> Bool
        func matches(_ t: Tokens) -> Bool { matches(t) }
    }

    private static func pkg(_ names: String..., kind: ServiceKind) -> Rule {
        Rule(kind: kind) { t in names.contains { t.has($0) } }
    }

    private static let rules: [Rule] = [
        pkg("next", "next-server", "next-router-worker", kind: .tool("next", "Next.js", brand: "nextdotjs")),
        pkg("astro", kind: .tool("astro", "Astro", brand: "astro")),
        pkg("nuxt", "nuxi", kind: .tool("nuxt", "Nuxt", brand: "nuxt")),
        pkg("remix", "react-router", kind: .tool("remix", "Remix", brand: "remix")),
        pkg("svelte-kit", kind: .tool("sveltekit", "SvelteKit", brand: "svelte")),
        pkg("storybook", "sb", "start-storybook", kind: .tool("storybook", "Storybook", brand: "storybook")),
        pkg("expo", "metro", "react-native", kind: .tool("expo", "Expo", brand: "expo")),
        pkg("wrangler", "workerd", "miniflare", kind: .tool("wrangler", "Wrangler", brand: "cloudflare")),
        pkg("vercel", kind: .tool("vercel", "Vercel", brand: "vercel")),
        pkg("convex", "convex-local-backend", kind: .tool("convex", "Convex", brand: "convex", http: false)),
        pkg("supabase", kind: .tool("supabase", "Supabase", brand: "supabase", http: false)),
        pkg("prisma", kind: .tool("prisma", "Prisma Studio", brand: "prisma")),
        pkg("drizzle-kit", kind: .tool("drizzle", "Drizzle Studio", brand: "drizzle")),
        pkg("ng", "@angular/cli", kind: .tool("angular", "Angular", brand: "angular")),
        pkg("vue-cli-service", kind: .tool("vue", "Vue", brand: "vuedotjs")),
        pkg("webpack", "webpack-dev-server", "webpack-cli", kind: .tool("webpack", "webpack", brand: "webpack")),
        pkg("vitest", kind: .tool("vitest", "Vitest", brand: "vitest", http: false)),
        pkg("jest", kind: .tool("jest", "Jest", brand: "jest", http: false)),
        pkg("playwright", kind: .tool("playwright", "Playwright", brand: nil, symbol: "theatermasks", http: false)),
        pkg("electron", "electron-vite", kind: .tool("electron", "Electron", brand: "electron", http: false)),
        pkg("tauri", kind: .tool("tauri", "Tauri", brand: "tauri", http: false)),
        pkg("tsc", kind: .tool("tsc", "TypeScript", brand: "typescript", http: false)),
        pkg("tsx", "ts-node", kind: .tool("tsx", "TypeScript", brand: "typescript")),
        pkg("hono", kind: .tool("hono", "Hono", brand: "hono")),
        // Vite last among JS tools: many tools above embed it.
        pkg("vite", kind: .tool("vite", "Vite", brand: "vite")),

        // Python
        pkg("uvicorn", "fastapi", "hypercorn", kind: .tool("fastapi", "FastAPI", brand: "fastapi")),
        Rule(kind: .tool("django", "Django", brand: "django")) { t in
            t.argBases.contains("manage.py") || t.has("django-admin") || t.has("daphne")
        },
        pkg("flask", kind: .tool("flask", "Flask", brand: "flask")),
        pkg("gunicorn", kind: .tool("gunicorn", "Gunicorn", brand: "python")),
        pkg("jupyter", "jupyter-lab", "jupyter-notebook", kind: .tool("jupyter", "Jupyter", brand: nil, symbol: "book.pages")),

        // Other languages
        Rule(kind: .tool("rails", "Rails", brand: "rubyonrails")) { t in
            t.has("rails") || t.has("puma") || t.has("foreman")
        },
        Rule(kind: .tool("laravel", "Laravel", brand: "laravel")) { t in t.argBases.contains("artisan") },
        Rule(kind: .tool("phoenix", "Phoenix", brand: "elixir")) { t in t.args.contains("phx.server") },
        Rule(kind: .tool("go", "Go", brand: "go")) { t in
            t.exeBase == "air" || (t.exeBase == "go" && t.args.dropFirst().first == "run")
                || t.joined.contains("/go-build")
        },
        Rule(kind: .tool("rust", "Rust", brand: "rust")) { t in
            t.exeBase == "cargo" || t.exeBase == "cargo-watch" || t.executable.contains("/target/debug/")
        },

        // Databases and infrastructure
        Rule(kind: .tool("postgres", "PostgreSQL", brand: "postgresql", http: false)) { t in
            t.exeBase == "postgres" || t.exeBase == "postmaster"
        },
        Rule(kind: .tool("redis", "Redis", brand: "redis", http: false)) { t in
            t.exeBase == "redis-server" || t.exeBase == "valkey-server"
        },
        Rule(kind: .tool("mongodb", "MongoDB", brand: "mongodb", http: false)) { t in t.exeBase == "mongod" },
        Rule(kind: .tool("mysql", "MySQL", brand: "mysql", http: false)) { t in
            t.exeBase == "mysqld" || t.exeBase == "mariadbd"
        },
        Rule(kind: .tool("nginx", "nginx", brand: "nginx")) { t in t.exeBase == "nginx" },
        Rule(kind: .tool("ollama", "Ollama", brand: "ollama")) { t in t.exeBase == "ollama" },
        Rule(kind: .tool("docker", "Docker", brand: "docker", http: false)) { t in
            t.exeBase == "com.docker.backend" || t.exeBase == "docker-proxy" || t.exeBase == "vpnkit-bridge"
                || t.exeBase == "orbstack" || t.exeBase == "OrbStack Helper"
        },
        Rule(kind: .tool("emulator", "Android Emulator", brand: nil, symbol: "smartphone", http: false)) { t in
            t.exeBase.hasPrefix("qemu-system") || t.exeBase == "emulator"
        },
        Rule(kind: .tool("adb", "adb", brand: nil, symbol: "cable.connector", http: false)) { t in t.exeBase == "adb" },
        Rule(kind: .tool("simulator", "iOS Simulator", brand: nil, symbol: "iphone", http: false)) { t in
            t.exeBase == "launchd_sim"
        },
        Rule(kind: .tool("php", "PHP", brand: "php")) { t in
            t.exeBase.hasPrefix("php") && t.args.contains("-S")
        },
    ]
}

/// Pre-digested argv for matching.
private struct Tokens {
    let executable: String
    let exeBase: String
    let args: [String]
    /// Basenames of every argument that looks like a path or a word.
    let argBases: [String]
    /// Package names found in `node_modules/<pkg>/...` or `node_modules/.bin/<pkg>` paths.
    let jsPackages: [String]
    /// Basename of the script an interpreter runs (`node foo.js` → foo.js).
    let scriptBase: String?
    let joined: String

    init(_ p: RawProcess) {
        executable = p.executable
        // Processes that set `process.title` put everything into argv[0].
        var argv = p.args
        if argv.count == 1, argv[0].contains(" ") {
            argv = argv[0].split(separator: " ").map(String.init)
        }
        args = argv
        let exe = argv.first.map { ($0 as NSString).lastPathComponent } ?? ""
        let pathExe = (p.executable as NSString).lastPathComponent
        exeBase = Self.normalize(exe.isEmpty ? pathExe : exe)
        argBases = argv.dropFirst().map { ($0 as NSString).lastPathComponent }
        joined = argv.joined(separator: " ")

        var pkgs: [String] = []
        for a in argv {
            guard let range = a.range(of: "node_modules/", options: .backwards) else { continue }
            let rest = a[range.upperBound...].split(separator: "/").map(String.init)
            if rest.first == ".bin", rest.count > 1 { pkgs.append(rest[1]) }
            else if let first = rest.first {
                if first.hasPrefix("@"), rest.count > 1 { pkgs.append("\(first)/\(rest[1])") }
                else { pkgs.append(first) }
            }
        }
        jsPackages = pkgs

        let interpreters: Set = ["node", "bun", "deno", "python", "ruby", "php"]
        if interpreters.contains(exeBase) {
            scriptBase = argv.dropFirst().first(where: { !$0.hasPrefix("-") }).map { ($0 as NSString).lastPathComponent }
        } else {
            scriptBase = nil
        }
    }

    /// `python3.12` → `python`, `node22` → `node`.
    private static func normalize(_ s: String) -> String {
        if s.hasPrefix("python") { return "python" }
        if s.hasPrefix("node") && s.count <= 6 { return "node" }
        if s.hasPrefix("ruby") { return "ruby" }
        return s
    }

    /// True when `name` is the executable, the script, a JS package in a path, or a bare word in argv.
    func has(_ name: String) -> Bool {
        if exeBase == name || scriptBase == name || jsPackages.contains(name) { return true }
        if exeBase.hasPrefix(name + " (") { return true } // "next-server (v15.5.0)"
        // `bunx vite`, `python -m uvicorn`, `npx next dev`: a bare word near the start of argv.
        for a in args.dropFirst().prefix(4) where a == name { return true }
        return false
    }

    var runtimeKind: ServiceKind {
        switch exeBase {
        case "node": return .runtime("node", "Node.js", brand: "nodedotjs")
        case "bun", "bunx": return .runtime("bun", "Bun", brand: "bun")
        case "deno": return .runtime("deno", "Deno", brand: "deno")
        case "python": return .runtime("python", "Python", brand: "python")
        case "ruby": return .runtime("ruby", "Ruby", brand: "rubyonrails")
        case "php": return .runtime("php", "PHP", brand: "php")
        case "sh", "bash", "zsh", "fish": return .runtime("shell", "Shell", brand: nil, symbol: "terminal")
        default: return .runtime(exeBase, exeBase, brand: nil, symbol: "gearshape")
        }
    }
}
