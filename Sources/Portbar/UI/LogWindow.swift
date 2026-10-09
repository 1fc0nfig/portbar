import SwiftUI

struct LogWindow: View {
    let runID: UUID?
    let model: AppModel
    @State private var follow = true
    @State private var filter = ""

    private var run: ManagedRun? { model.runner.runs.first { $0.id == runID } }

    var body: some View {
        if let run {
            VStack(spacing: 0) {
                toolbar(run)
                Divider()
                if let service = model.service(for: run) {
                    serviceHeader(service, run: run)
                    Divider()
                }
                ScrollViewReader { proxy in
                    ScrollView {
                        let lines = filtered(run.log.lines)
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(lines.indices, id: \.self) { i in
                                Text(lines[i].plain.isEmpty ? AttributedString(" ") : lines[i].styled)
                                    .font(.system(size: 11.5, design: .monospaced))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                            }
                            Color.clear.frame(height: 1).id("bottom")
                        }
                        .padding(12)
                    }
                    .onChange(of: run.log.lines.count) {
                        if follow { proxy.scrollTo("bottom", anchor: .bottom) }
                    }
                    .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }
            .frame(minWidth: 560, minHeight: 320)
            .navigationTitle("\(run.name) · \((run.directory as NSString).lastPathComponent)")
        } else {
            Text("This run is gone.")
                .foregroundStyle(.secondary)
                .frame(minWidth: 400, minHeight: 200)
        }
    }

    private func toolbar(_ run: ManagedRun) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(run.isRunning ? Color(nsColor: .systemGreen)
                      : run.failed ? Color(nsColor: .systemRed) : Color.secondary)
                .frame(width: 7, height: 7)
            Text(run.command)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if let exit = run.exit { ExitBadge(exit: exit, failed: run.failed) }
            Spacer()
            TextField("Filter", text: $filter)
                .textFieldStyle(.roundedBorder)
                .frame(width: 160)
            Toggle("Follow", isOn: $follow)
                .toggleStyle(.checkbox)
            Button("Copy") { ProcessControl.copy(run.log.text) }
            // While the service is up, the controls below handle restart and stop.
            if !run.isRunning {
                Button("Run Again") { model.runner.restart(run) }
            } else if model.service(for: run) == nil {
                Button("Restart") { model.runner.restart(run) }
                Button("Stop") { model.stop(run) }
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// The same stats and controls as the panel details, while the run has a live service.
    private func serviceHeader(_ service: Service, run: ManagedRun) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let issue = service.issues.sorted().first {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    IssueDot(issue: issue)
                    Text(issue.explanation)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            ServiceStats(service: service, model: model)
            ServiceActions(service: service, model: model, run: run, inLogWindow: true)
        }
        .padding(12)
    }

    private func filtered(_ lines: [LogLine]) -> [LogLine] {
        guard !filter.isEmpty else { return lines }
        return lines.filter { $0.plain.localizedCaseInsensitiveContains(filter) }
    }
}
