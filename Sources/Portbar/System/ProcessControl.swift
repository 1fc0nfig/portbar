import AppKit
import Darwin

enum ProcessControl {
    /// Sends SIGTERM to the service processes, then SIGKILL to the ones still alive after 3 seconds.
    /// With `includeLaunchers`, also stops the wrappers that started it (`bun run dev`, `concurrently`).
    static func stop(_ service: Service, includeLaunchers: Bool = false, force: Bool = false) {
        var pids = service.allPids
        if includeLaunchers { pids += service.launchers.map(\.pid) }
        // Children first, so parents do not respawn them.
        pids.sort(by: >)
        let signal = force ? SIGKILL : SIGTERM
        for pid in pids { kill(pid, signal) }
        guard !force else { return }
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            for pid in pids where kill(pid, 0) == 0 { kill(pid, SIGKILL) }
        }
    }

    /// Stops `root` and every process below it.
    static func killTree(_ root: pid_t, force: Bool, wait: Bool = true) {
        var pids = [root] + descendants(of: root)
        pids.sort(by: >)
        for pid in pids { kill(pid, force ? SIGKILL : SIGTERM) }
        guard !force, wait else { return }
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            for pid in pids where kill(pid, 0) == 0 { kill(pid, SIGKILL) }
        }
    }

    static func descendants(of root: pid_t) -> [pid_t] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let n = pids.withUnsafeMutableBufferPointer {
            proc_listallpids($0.baseAddress, Int32($0.count * MemoryLayout<pid_t>.size))
        }
        var children: [pid_t: [pid_t]] = [:]
        for pid in pids.prefix(Int(max(n, 0))) where pid > 0 {
            var info = proc_bsdshortinfo()
            let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, size) == size else { continue }
            children[pid_t(info.pbsi_ppid), default: []].append(pid)
        }
        var result: [pid_t] = []
        var queue = [root]
        while let next = queue.popLast() {
            for c in children[next] ?? [] where !result.contains(c) {
                result.append(c)
                queue.append(c)
            }
        }
        return result
    }

    static func open(_ service: Service, port: UInt16? = nil) {
        guard let port = port ?? service.ports.first,
              let url = URL(string: "http://localhost:\(port)") else { return }
        NSWorkspace.shared.open(url)
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    static func revealInFinder(_ path: String) {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
    }

    /// First installed editor, in order of preference.
    static let editor: (name: String, url: URL)? = {
        let ids = [("Cursor", "com.todesktop.230313mzl4w4u92"), ("Zed", "dev.zed.Zed"),
                   ("VS Code", "com.microsoft.VSCode"), ("Xcode", "com.apple.dt.Xcode")]
        for (name, id) in ids {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) { return (name, url) }
        }
        return nil
    }()

    static let editorIcon: NSImage? = editor.map { NSWorkspace.shared.icon(forFile: $0.url.path) }

    static func openInEditor(_ path: String) {
        guard let editor else { return }
        NSWorkspace.shared.open([URL(fileURLWithPath: path)], withApplicationAt: editor.url,
                                configuration: NSWorkspace.OpenConfiguration())
    }
}
