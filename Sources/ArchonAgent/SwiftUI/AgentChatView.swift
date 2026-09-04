import SwiftUI

/// Ready-to-use SwiftUI chat interface supporting streaming agent responses and tool badges.
public struct AgentChatView<State: AgentState>: View {
    @Bindable public var viewModel: AgentViewModel<State>
    @State private var inputText: String = ""

    public init(viewModel: AgentViewModel<State>) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header Status Bar
            HStack {
                Circle()
                    .fill(viewModel.isExecuting ? Color.green : Color.gray)
                    .frame(width: 8, height: 8)
                Text(viewModel.isExecuting ? "Executing: \(viewModel.currentNodeId)" : "Idle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial)

            // Human in the Loop approval banner
            if let interrupt = viewModel.pendingInterrupt {
                InterruptApprovalBanner(
                    interrupt: interrupt,
                    onApprove: { viewModel.resume(approved: true) },
                    onReject: { viewModel.resume(approved: false) }
                )
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            // Message Scroll Area
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(viewModel.messages) { msg in
                        HStack {
                            if msg.role == .user { Spacer() }
                            VStack(alignment: msg.role == .user ? .trailing : .leading, spacing: 4) {
                                Text(msg.content)
                                    .padding(12)
                                    .background(msg.role == .user ? Color.purple : Color.secondary.opacity(0.15))
                                    .foregroundStyle(msg.role == .user ? .white : .primary)
                                    .clipShape(RoundedRectangle(cornerRadius: 16))

                                if let calls = msg.toolCalls, !calls.isEmpty {
                                    ForEach(calls) { call in
                                        HStack(spacing: 4) {
                                            Image(systemName: "wrench.and.screwdriver")
                                            Text(call.name)
                                        }
                                        .font(.caption2)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(Color.orange.opacity(0.2))
                                        .clipShape(Capsule())
                                    }
                                }
                            }
                            if msg.role != .user { Spacer() }
                        }
                    }
                }
                .padding()
            }

            Divider()

            // Input Bar
            HStack(spacing: 8) {
                TextField("Message ArchonAgent...", text: $inputText)
                    .textFieldStyle(.roundedBorder)

                Button(action: {
                    guard !inputText.isEmpty else { return }
                    viewModel.messages.append(ChatMessage.user(inputText))
                    inputText = ""
                    viewModel.start()
                }) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                }
                .disabled(inputText.isEmpty || viewModel.isExecuting)
            }
            .padding()
        }
    }
}

/// Interactive banner for approving or rejecting human-in-the-loop actions.
public struct InterruptApprovalBanner: View {
    public let interrupt: GraphInterrupt
    public let onApprove: () -> Void
    public let onReject: () -> Void

    public init(interrupt: GraphInterrupt, onApprove: @escaping () -> Void, onReject: @escaping () -> Void) {
        self.interrupt = interrupt
        self.onApprove = onApprove
        self.onReject = onReject
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "exclamationmark.shield.fill")
                    .foregroundStyle(.orange)
                Text("Approval Required")
                    .font(.headline)
            }

            Text(interrupt.message)
                .font(.subheadline)

            HStack {
                Button("Reject", role: .destructive, action: onReject)
                    .buttonStyle(.bordered)

                Button("Approve", action: onApprove)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .background(Color.orange.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
    }
}

/// Time-travel inspection component for scrubbing past state checkpoints.
public struct TimeTravelInspectorView: View {
    public let checkpoints: [CheckpointRecord]
    public let onSelect: (CheckpointRecord) -> Void

    public init(checkpoints: [CheckpointRecord], onSelect: @escaping (CheckpointRecord) -> Void) {
        self.checkpoints = checkpoints
        self.onSelect = onSelect
    }

    public var body: some View {
        List(checkpoints) { checkpoint in
            Button(action: { onSelect(checkpoint) }) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Step \(checkpoint.stepIndex): \(checkpoint.nodeId)")
                            .font(.headline)
                        Spacer()
                        Text(checkpoint.timestamp.formatted(date: .omitted, time: .standard))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text("ID: \(checkpoint.checkpointId.prefix(8))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
