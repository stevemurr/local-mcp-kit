import SwiftUI
import LocalMCPTwoProducerExampleSupport

struct TwoProducerDemoView: View {
    @ObservedObject var model: TwoProducerDemoViewModel

    private let columns = [
        GridItem(.flexible(), spacing: 18),
        GridItem(.flexible(), spacing: 18),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                if let error = model.errorMessage {
                    errorBanner(error)
                }
                LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                    producerCard(.greeter)
                    producerCard(.calculator)
                }
                eventTimeline
                demoNotice
            }
            .padding(28)
        }
        .frame(minWidth: 780, minHeight: 620)
        .background(Color(nsColor: .windowBackgroundColor))
        .task { model.start() }
        .onDisappear { model.stop() }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("LocalMCPKit Two-Producer Demo")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .accessibilityIdentifier("demo-title")
                Text("One consumer identity · two isolated producer grants · in-memory transport")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 10) {
                discoveryPill
                Button {
                    model.reset()
                } label: {
                    Label("Reset demo", systemImage: "arrow.clockwise")
                }
                .accessibilityIdentifier("reset-demo")
                .disabled(model.isResetting || !model.busyProducers.isEmpty)
            }
        }
    }

    private var discoveryPill: some View {
        let count = model.snapshot.producers.filter { $0.status != .offline }.count
        return HStack(spacing: 7) {
            Circle()
                .fill(model.snapshot.isRunning ? Color.green : Color.orange)
                .frame(width: 8, height: 8)
            Text(model.snapshot.isRunning ? "\(count) producers discovered" : "Starting producers…")
                .font(.caption.weight(.semibold))
                .accessibilityIdentifier("discovery-status")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.thinMaterial, in: Capsule())
    }

    @ViewBuilder
    private func producerCard(_ kind: DemoProducerKind) -> some View {
        let producer = model.snapshot.producer(kind) ?? .placeholder(kind)
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: kind == .greeter ? "hand.wave.fill" : "plus.forwardslash.minus")
                    .font(.title2)
                    .foregroundStyle(kind == .greeter ? Color.indigo : Color.teal)
                    .frame(width: 36, height: 36)
                    .background(
                        (kind == .greeter ? Color.indigo : Color.teal).opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 9)
                    )
                VStack(alignment: .leading, spacing: 3) {
                    Text(producer.displayName)
                        .font(.headline)
                    Text(producer.stableID)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                statusBadge(producer.status, kind: kind)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("DISCOVERED ENDPOINT")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(producer.endpoint ?? "Waiting for discovery…")
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .accessibilityIdentifier("endpoint-\(kind.rawValue)")
            }

            HStack {
                Label(kind.commandName, systemImage: "wrench.and.screwdriver")
                    .font(.callout.monospaced())
                Spacer()
                if producer.tools.contains(kind.commandName) {
                    Text("listed")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.green)
                }
            }
            .padding(10)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))

            Group {
                if kind == .greeter {
                    greetingControls(producer)
                } else {
                    calculatorControls(producer)
                }
            }

            Divider()

            HStack {
                Button(producer.status == .revoked ? "Pair again" : "Pair") {
                    model.pair(with: kind)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("pair-\(kind.rawValue)")
                .disabled(model.isBusy(kind) || producer.status == .paired || producer.status == .offline)

                if producer.status == .paired {
                    Button("Revoke") {
                        model.revoke(kind)
                    }
                    .accessibilityIdentifier("revoke-\(kind.rawValue)")
                    .disabled(model.isBusy(kind))
                }

                Spacer()
                if model.isBusy(kind) {
                    ProgressView()
                        .controlSize(.small)
                }
            }
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }

    private func greetingControls(_ producer: DemoProducerSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Name", text: $model.greetingName)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("greeting-name")
            Button("Send greeting") {
                model.sendGreeting()
            }
            .accessibilityIdentifier("call-greeter")
            .disabled(!producer.isPaired || model.isBusy(.greeter))
            resultView(producer, placeholder: "Pair, then call the greeting tool.")
        }
    }

    private func calculatorControls(_ producer: DemoProducerSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("Left", text: $model.leftOperand)
                    .accessibilityIdentifier("calculator-left")
                Text("+")
                    .foregroundStyle(.secondary)
                TextField("Right", text: $model.rightOperand)
                    .accessibilityIdentifier("calculator-right")
            }
            .textFieldStyle(.roundedBorder)
            Button("Add values") {
                model.calculate()
            }
            .accessibilityIdentifier("call-calculator")
            .disabled(!producer.isPaired || model.isBusy(.calculator))
            resultView(producer, placeholder: "Pair, then call the addition tool.")
        }
    }

    private func resultView(_ producer: DemoProducerSnapshot, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("RESULT")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(producer.lastResult ?? placeholder)
                .font(.callout)
                .foregroundStyle(producer.lastResult == nil ? .secondary : .primary)
                .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
                .accessibilityIdentifier("result-\(producer.kind.rawValue)")
        }
    }

    private func statusBadge(_ status: DemoProducerStatus, kind: DemoProducerKind) -> some View {
        Text(statusLabel(status))
            .font(.caption.weight(.semibold))
            .foregroundStyle(statusColor(status))
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(statusColor(status).opacity(0.12), in: Capsule())
            .accessibilityIdentifier("status-\(kind.rawValue)")
    }

    private var eventTimeline: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Safe event timeline")
                .font(.headline)
            if model.snapshot.events.isEmpty {
                Text("Waiting for the example to start…")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(model.snapshot.events.enumerated()), id: \.offset) { _, event in
                    HStack(alignment: .firstTextBaseline, spacing: 9) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text(event)
                            .font(.callout)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityIdentifier("event-timeline")
    }

    private var demoNotice: some View {
        Label(
            "This sample auto-approves producer pairing so the whole flow fits in one window. Production apps must show a real producer-owned approval prompt. No credential or verification code is retained in the timeline.",
            systemImage: "info.circle"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("demo-security-notice")
    }

    private func errorBanner(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.red)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
            .accessibilityIdentifier("error-message")
    }

    private func statusLabel(_ status: DemoProducerStatus) -> String {
        switch status {
        case .offline: "Offline"
        case .discovered: "Discovered"
        case .paired: "Paired"
        case .revoked: "Revoked"
        }
    }

    private func statusColor(_ status: DemoProducerStatus) -> Color {
        switch status {
        case .offline: .secondary
        case .discovered: .orange
        case .paired: .green
        case .revoked: .red
        }
    }
}

private extension DemoProducerSnapshot {
    static func placeholder(_ kind: DemoProducerKind) -> DemoProducerSnapshot {
        TwoProducerDemoSnapshot.empty.producer(kind)!
    }
}
