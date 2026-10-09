import AppKit
import SwiftUI

/// `portbar --dump` prints what the panel would show. `--render out.png` saves the panel as an image.
enum DebugTools {
    static func dump() {
        let graph = ServiceGraph()
        _ = graph.build(unresponsive: [])
        Thread.sleep(forTimeInterval: 1)   // second scan gives CPU deltas
        let snap = graph.build(unresponsive: [])
        for project in snap.projects {
            print("\(project.name)  \(project.path ?? "")")
            for w in project.worktrees {
                if let b = w.branch { print("  [\(b)\(w.isLinked ? " · worktree \(w.path ?? "")" : "")]") }
                for s in w.services {
                    let ports = s.ports.map { ":\($0)" }.joined(separator: " ")
                    let issues = s.issues.map(\.label).joined(separator: ", ")
                    print("    \(s.kind.name.padding(toLength: 14, withPad: " ", startingAt: 0)) "
                          + "\(ports.padding(toLength: 12, withPad: " ", startingAt: 0)) "
                          + "\(s.command.prefix(60))  pid \(s.root.pid) +\(s.members.count - 1)"
                          + "\(s.relativeDirectory.map { "  (\($0))" } ?? "")"
                          + "\(s.launcherCommand.map { "  via: \($0.prefix(40))" } ?? "")"
                          + (issues.isEmpty ? "" : "  !! \(issues)"))
                }
            }
        }
    }

    /// `--run-test <dir> <script>`: start a package.json script, check logs and service matching, then stop it.
    @MainActor
    static func runTest(dir: String, script name: String) {
        _ = NSApplication.shared
        let model = AppModel()
        guard let script = model.catalog.packageScripts(in: dir).first(where: { $0.name == name }) else {
            print("no script \(name) in \(dir)"); return
        }
        print("command: \(script.command)")
        model.start(script, projectID: dir, directory: dir)
        let run = model.runner.runs[0]
        RunLoop.main.run(until: Date().addingTimeInterval(6))
        print("pid \(run.pid) running=\(run.isRunning)")
        print("log:\n  " + run.log.lines.suffix(6).map(\.plain).joined(separator: "\n  "))
        for p in model.projects {
            for s in p.services {
                print("service \(s.kind.name) \(s.ports) managed=\(model.run(for: s) != nil) project=\(p.name)")
            }
            for r in p.looseRuns { print("loose run \(r.name) in \(p.name)") }
        }
        model.stop(run)
        RunLoop.main.run(until: Date().addingTimeInterval(4))
        print("after stop: running=\(run.isRunning) exit=\(run.exit?.long ?? "nil") "
              + "descendants alive=\(ProcessControl.descendants(of: run.pid).count) root alive=\(kill(run.pid, 0) == 0)")
    }

    /// `--start <dir> <script>`: start a script, wait, and quit without stopping it. `--adopt` picks it up.
    @MainActor
    static func startAndLeave(dir: String, script name: String) {
        _ = NSApplication.shared
        let model = AppModel()
        guard let script = model.catalog.packageScripts(in: dir).first(where: { $0.name == name }) else {
            print("no script \(name) in \(dir)"); return
        }
        model.start(script, projectID: dir, directory: dir)
        RunLoop.main.run(until: Date().addingTimeInterval(3))
        let run = model.runner.runs.last!
        print("started pid \(run.pid), \(run.log.lines.count) log lines, left running")
    }

    /// `--adopt`: show the runs an earlier portbar left running, follow their logs, then stop them.
    @MainActor
    static func adopt() {
        _ = NSApplication.shared
        let model = AppModel()
        let runs = model.runner.runs
        print("adopted \(runs.count) runs")
        for run in runs { print("  \(run.name) pid \(run.pid): \(run.log.lines.count) lines") }
        RunLoop.main.run(until: Date().addingTimeInterval(2))
        for run in runs {
            print("  \(run.name) after 2s: \(run.log.lines.count) lines, last: \(run.log.lines.last?.plain ?? "")")
            model.stop(run)
        }
        RunLoop.main.run(until: Date().addingTimeInterval(4))
        for run in runs {
            print("  \(run.name) after stop: running=\(run.isRunning) last: \(run.log.lines.last?.plain ?? "")")
        }
    }

    @MainActor
    static func renderLogSample(to path: String) {
        let esc = "\u{1B}"
        let sample = [
            "$ bun run dev",
            "\(esc)[1m\(esc)[35m▲ Next.js 15.5.0\(esc)[39m\(esc)[22m (Turbopack)",
            "   - Local:        http://localhost:3000",
            " \(esc)[32m✓\(esc)[39m Starting...",
            " \(esc)[32m✓\(esc)[39m Ready in \(esc)[1m1204ms\(esc)[22m",
            " \(esc)[90m○\(esc)[39m Compiling / ...",
            "\(esc)[33mwarn\(esc)[39m  - Fast Refresh had to perform a full reload.",
            " GET / \(esc)[32m200\(esc)[39m in 212ms",
            " \(esc)[42m\(esc)[30m PASS \(esc)[39m\(esc)[49m src/app.test.ts \(esc)[2m(12 tests)\(esc)[22m",
            "\(esc)[38;5;208m256-color orange\(esc)[0m and \(esc)[38;2;120;180;255mtruecolor blue\(esc)[0m",
            "Error: Cannot find module './missing'",
            "npm WARN deprecated inflight@1.0.6",
            "[exit 1]",
        ].joined(separator: "\n") + "\n"
        let log = LogBuffer()
        log.append(sample)
        let view = VStack(alignment: .leading, spacing: 0) {
            ForEach(log.lines.indices, id: \.self) { i in
                Text(log.lines[i].styled).font(.system(size: 11.5, design: .monospaced))
            }
        }
        .padding(12)
        .frame(width: 560, alignment: .leading)
        .background(Color(nsColor: .textBackgroundColor))
        .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        if let tiff = renderer.nsImage?.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
        }
    }

    @MainActor
    static func render(to path: String) {
        _ = NSApplication.shared
        PanelView.isRendering = true
        let model = AppModel()
        // `--pin <path>` pins projects, `--compact` switches density. Changes stay in the CLI defaults domain.
        let args = CommandLine.arguments
        for (i, a) in args.enumerated() where a == "--pin" && i + 1 < args.count {
            model.settings.setPinned(args[i + 1], true)
        }
        for (i, a) in args.enumerated() where a == "--add" && i + 1 < args.count {
            model.settings.add(args[i + 1])
        }
        model.settings.value.density = args.contains("--compact") ? .compact : .regular
        // Wait for the first background scan.
        let deadline = Date().addingTimeInterval(4)
        while model.snapshot.projects.isEmpty && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        // A few scans so the charts have history.
        if args.contains("--expand") {
            for _ in 0..<6 {
                model.refresh()
                RunLoop.main.run(until: Date().addingTimeInterval(1.1))
            }
        }
        if args.contains("--fake-stopped"), let s = model.snapshot.services.first(where: { $0.location != nil }) {
            // Three rows, so the older two fold under one line.
            for _ in 0..<3 {
                model.stopped.append(StoppedEntry(projectID: s.location!.repoRoot, kind: .tool("storybook", "Storybook", brand: "storybook"),
                                                  command: "bun run storybook", directory: s.directory, ports: [6006], run: nil))
            }
        }
        let expanded = args.contains("--expand") ? model.projects.flatMap(\.services).first(where: { !$0.ports.isEmpty })?.id : nil
        let view = PanelView(model: model, expandedID: expanded)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
            print("render failed"); return
        }
        try? png.write(to: URL(fileURLWithPath: path))

        let addView = AddProjectView(model: model)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, .dark)
        let addRenderer = ImageRenderer(content: addView)
        addRenderer.scale = 2
        if let tiff = addRenderer.nsImage?.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: (path as NSString).deletingPathExtension + "-add.png"))
        }

        renderLogSample(to: (path as NSString).deletingPathExtension + "-logs.png")

        // Menu bar mark samples at 8x, on light and dark strips.
        let samples: [[DotState]] = [model.dots, [.running, .running, .stopped, .empty], [.running, .warning, .stopped, .empty], [.critical, .running, .warning, .stopped]]
        let strip = NSImage(size: NSSize(width: 24 * CGFloat(samples.count), height: 48), flipped: false) { _ in
            for (row, bg) in [NSColor.white, NSColor(white: 0.12, alpha: 1)].enumerated() {
                NSAppearance(named: row == 0 ? .aqua : .darkAqua)!.performAsCurrentDrawingAppearance {
                    bg.setFill(); NSRect(x: 0, y: CGFloat(row) * 24, width: 24 * CGFloat(samples.count), height: 24).fill()
                    for (i, states) in samples.enumerated() {
                        let img = MenuBarIcon.dots(states)
                        let rect = NSRect(x: CGFloat(i) * 24 + 4, y: CGFloat(row) * 24 + 4, width: 16, height: 16)
                        if img.isTemplate {
                            let tinted = NSImage(size: img.size, flipped: false) { r in
                                img.draw(in: r)
                                (row == 0 ? NSColor.black : NSColor.white).set()
                                r.fill(using: .sourceAtop)
                                return true
                            }
                            tinted.draw(in: rect)
                        } else {
                            img.draw(in: rect)
                        }
                    }
                }
            }
            return true
        }
        let dotsRenderer = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 24 * samples.count * 8, pixelsHigh: 48 * 8,
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        dotsRenderer.size = strip.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: dotsRenderer)
        strip.draw(in: NSRect(origin: .zero, size: strip.size))
        NSGraphicsContext.restoreGraphicsState()
        let dotsPath = (path as NSString).deletingPathExtension + "-menubar.png"
        try? dotsRenderer.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dotsPath))
        print("wrote \(path)")
    }
}
