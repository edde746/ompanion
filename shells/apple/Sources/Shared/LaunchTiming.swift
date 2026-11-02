import Foundation

/// The launch's `shell timing` line (docs/contracts/bridge.md, Shell services: shell.timing): the kernel's start of
/// this process as epoch ms, then ms from it to the shell's first code (the app delegate makes the shell), to the web
/// view's creation and to each stage the page reports, in the order they happened. Written once, when the launch's page
/// reports, to stderr and to the file $OMPCORE_LOG names.
@MainActor
final class LaunchTiming {
    private let start: Date
    private var stages: [(String, Double)] = []
    private var written = false

    init() {
        start = Self.processStart()
        mark("shellMs")
    }

    /// Notes `name`'s time; only its first.
    func mark(_ name: String, at date: Date = Date()) {
        guard !stages.contains(where: { $0.0 == name }) else { return }
        stages.append((name, date.timeIntervalSince(start) * 1000))
    }

    /// shell.timing: `page` maps each of the page's stages to its epoch ms.
    func write(page: [String: Any]) throws {
        guard !written else { return }
        written = true
        let startMs = start.timeIntervalSince1970 * 1000
        for (name, value) in page {
            guard let epochMs = value as? Double else { throw ShellError("\(name) must be a number") }
            stages.append((name + "Ms", epochMs - startMs))
        }
        stages.sort { $0.1 < $1.1 }
        let fields = [String(format: "\"processStartEpochMs\":%.1f", startMs)]
            + stages.map { String(format: "\"%@\":%.1f", $0.0, $0.1) }
        let data = Data("shell timing {\(fields.joined(separator: ","))}\n".utf8)
        try FileHandle.standardError.write(contentsOf: data)
        if let path = ProcessInfo.processInfo.environment["OMPCORE_LOG"] {
            let fd = open(path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
            guard fd >= 0 else { throw ShellError("opening \(path) failed: \(String(cString: strerror(errno)))") }
            try FileHandle(fileDescriptor: fd, closeOnDealloc: true).write(contentsOf: data)
        }
    }

    /// When the kernel started this process.
    private static func processStart() -> Date {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&name, u_int(name.count), &info, &size, nil, 0) == 0 else {
            fatalError("reading the process's start time failed: \(String(cString: strerror(errno)))")
        }
        let time = info.kp_proc.p_starttime
        return Date(timeIntervalSince1970: TimeInterval(time.tv_sec) + TimeInterval(time.tv_usec) / 1_000_000)
    }
}
