import Darwin
import Foundation

/// One OS process as read from libproc. Only processes owned by the current user carry details.
struct RawProcess {
    let pid: pid_t
    let ppid: pid_t
    let name: String
    let executable: String
    let args: [String]
    let cwd: String?
    let startTime: Date
    let cpuTimeNs: UInt64
    let rssBytes: UInt64
    let hasTTY: Bool
    /// Started by a portbar script run (it has PORTBAR=1, or PORTRUNNER=1 from before the rename), maybe in an earlier session.
    let fromPortbar: Bool
    var listenPorts: [UInt16]
}

/// Reads the process table with libproc and sysctl. No subprocesses, no `lsof`.
final class ProcessScanner {
    private struct Static { let executable: String; let args: [String]; let fromPortbar: Bool }
    private var staticCache: [String: Static] = [:]   // key: "pid:start"
    private let uid = getuid()
    private let argMax: Int = {
        var mib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        sysctl(&mib, 2, &value, &size, nil, 0)
        return Int(value > 0 ? value : 262_144)
    }()
    private let timebase: (numer: UInt64, denom: UInt64) = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return (UInt64(info.numer), UInt64(max(info.denom, 1)))
    }()

    /// All processes of the current user, keyed by pid.
    func scan() -> [pid_t: RawProcess] {
        var result: [pid_t: RawProcess] = [:]
        var seen = Set<String>()

        for pid in allPids() where pid > 0 {
            var bsd = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, size) == size else { continue }
            guard bsd.pbi_uid == uid else { continue }

            let start = Date(timeIntervalSince1970: TimeInterval(bsd.pbi_start_tvsec)
                             + TimeInterval(bsd.pbi_start_tvusec) / 1_000_000)
            let key = "\(pid):\(bsd.pbi_start_tvsec)"
            seen.insert(key)

            let stat: Static
            if let cached = staticCache[key] {
                stat = cached
            } else {
                let (exe, args, env) = arguments(of: pid)
                stat = Static(executable: exe ?? executablePath(of: pid) ?? "", args: args,
                              fromPortbar: env.contains("PORTBAR=1") || env.contains("PORTRUNNER=1"))
                staticCache[key] = stat
            }

            var task = proc_taskinfo()
            let taskSize = Int32(MemoryLayout<proc_taskinfo>.size)
            var cpu: UInt64 = 0, rss: UInt64 = 0
            if proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, taskSize) == taskSize {
                cpu = (task.pti_total_user + task.pti_total_system) * timebase.numer / timebase.denom
                rss = task.pti_resident_size
            }

            let name = withUnsafeBytes(of: bsd.pbi_name) { cString($0) }
            let comm = withUnsafeBytes(of: bsd.pbi_comm) { cString($0) }

            result[pid] = RawProcess(
                pid: pid,
                ppid: pid_t(bsd.pbi_ppid),
                name: name.isEmpty ? comm : name,
                executable: stat.executable,
                args: stat.args,
                cwd: cwd(of: pid),
                startTime: start,
                cpuTimeNs: cpu,
                rssBytes: rss,
                hasTTY: bsd.e_tdev != UInt32.max && bsd.e_tdev != 0,
                fromPortbar: stat.fromPortbar,
                listenPorts: []
            )
        }

        staticCache = staticCache.filter { seen.contains($0.key) }
        return result
    }

    /// Listening TCP ports of one process.
    func listenPorts(of pid: pid_t) -> [UInt16] {
        let bufferSize = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bufferSize > 0 else { return [] }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bufferSize) / stride + 16)
        let used = fds.withUnsafeMutableBytes {
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count))
        }
        guard used > 0 else { return [] }

        var ports = Set<UInt16>()
        for fd in fds.prefix(Int(used) / stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var info = socket_fdinfo()
            let infoSize = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, infoSize) == infoSize else { continue }
            guard info.psi.soi_kind == Int32(SOCKINFO_TCP) else { continue }
            let tcp = info.psi.soi_proto.pri_tcp
            guard tcp.tcpsi_state == TSI_S_LISTEN else { continue }
            let port = UInt16(bigEndian: UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_lport))
            if port > 0 { ports.insert(port) }
        }
        return ports.sorted()
    }

    // MARK: - libproc helpers

    private func allPids() -> [pid_t] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 128)
        let n = pids.withUnsafeMutableBufferPointer {
            proc_listallpids($0.baseAddress, Int32($0.count * MemoryLayout<pid_t>.size))
        }
        return Array(pids.prefix(Int(max(n, 0))))
    }

    private func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let n = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard n > 0 else { return nil }
        return String(cString: buffer)
    }

    private func cwd(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { cString($0) }
        return path.isEmpty ? nil : path
    }

    /// argv and environment via KERN_PROCARGS2. Node and Bun rewrite argv when they set `process.title`, which we want.
    private func arguments(of pid: pid_t) -> (String?, [String], [String]) {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var buffer = [UInt8](repeating: 0, count: argMax)
        var size = buffer.count
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else {
            return (nil, [], [])
        }
        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        var i = MemoryLayout<Int32>.size

        func readString() -> String? {
            let start = i
            while i < size, buffer[i] != 0 { i += 1 }
            let s = String(decoding: buffer[start..<i], as: UTF8.self)
            return s
        }

        let exe = readString()
        while i < size, buffer[i] == 0 { i += 1 }

        var args: [String] = []
        while args.count < Int(argc), i < size {
            if let s = readString() { args.append(s) }
            i += 1
        }
        // The environment follows argv, up to an empty string.
        var env: [String] = []
        while i < size, buffer[i] != 0 {
            if let s = readString() { env.append(s) }
            i += 1
        }
        return (exe, args, env)
    }
}

private func cString(_ raw: UnsafeRawBufferPointer) -> String {
    let bytes = raw.bindMemory(to: UInt8.self)
    let end = bytes.firstIndex(of: 0) ?? bytes.count
    return String(decoding: bytes[0..<end], as: UTF8.self)
}
