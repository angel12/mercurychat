import ChatCore
import SwiftUI

/// One transcript row: user bubble, assistant bubble (markdown + collapsible
/// thinking), tool activity, or system notice.
struct TranscriptItemView: View {
    let item: TranscriptItem
    /// Called with the message id when the user taps retry on a failed send.
    var onRetryUser: ((String) -> Void)? = nil

    var body: some View {
        switch item {
        case .user(let message):
            UserBubble(message: message, onRetry: onRetryUser)
        case .assistant(let message):
            // Bubbles sealed empty at a tool boundary render as nothing.
            if message.text.isEmpty, message.reasoning.isEmpty,
                message.error == nil, !message.isStreaming
            {
                EmptyView()
            } else {
                AssistantBubble(message: message)
            }
        case .tool(let tool):
            ToolRow(tool: tool)
        case .notice(let notice):
            NoticeRow(notice: notice)
        }
    }
}

private struct UserBubble: View {
    let message: UserMessage
    var onRetry: ((String) -> Void)? = nil

    var body: some View {
        HStack {
            Spacer(minLength: 48)
            VStack(alignment: .trailing, spacing: 4) {
                if !message.attachments.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(message.attachments) { attachment in
                                if let previewData = attachment.previewData {
                                    AttachmentThumbnail(data: previewData)
                                        .frame(width: 120, height: 120)
                                        .clipShape(RoundedRectangle(cornerRadius: 10))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 10)
                                                .strokeBorder(.quaternary))
                                } else {
                                    // No preview bytes — hydrated rows, and
                                    // live file/PDF echoes, which never carry a
                                    // thumbnail. A compact chip, icon per kind.
                                    Label(
                                        attachment.filename,
                                        systemImage: chipIcon(attachment.kind))
                                        .font(.caption)
                                        .lineLimit(1)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 5)
                                        .background(.quaternary, in: Capsule())
                                }
                            }
                        }
                    }
                    // Only thumbnails need a fixed height. A hydrated row is
                    // all chips (no preview bytes) and sizes itself — pinning
                    // 124 there leaves a tall empty band above the caption.
                    .frame(
                        height: message.attachments.contains { $0.previewData != nil }
                            ? 124 : nil)
                }
                if !message.text.isEmpty {
                    Text(message.text)
                        .textSelection(.enabled)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(.tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 16))
                        .opacity(message.sendState == .sending ? 0.55 : 1)
                }
                switch message.sendState {
                case .queued:
                    Label("Queued — runs after the current turn", systemImage: "clock")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .failed:
                    Button {
                        onRetry?(message.id)
                    } label: {
                        Label("Not delivered — tap to retry", systemImage: "arrow.clockwise")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.red)
                case .sending, .sent:
                    EmptyView()
                }
            }
        }
        .padding(.horizontal)
    }

    /// SF Symbol for a byte-less attachment chip, matched to the composer
    /// tray's icons so a file looks the same before and after sending.
    private func chipIcon(_ kind: MessageAttachment.Kind) -> String {
        switch kind {
        case .image: "photo"
        case .pdf: "doc.richtext"
        case .file: "doc"
        }
    }
}

private struct AssistantBubble: View {
    let message: AssistantMessage
    @State private var showThinking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !message.reasoning.isEmpty {
                thinkingSection
            }
            if !message.text.isEmpty {
                MarkdownText(message.text)
            }
            if message.isStreaming && message.text.isEmpty && message.reasoning.isEmpty {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Thinking…").font(.callout).foregroundStyle(.secondary)
                }
            }
            if let error = message.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
    }

    private var thinkingSection: some View {
        DisclosureGroup(isExpanded: $showThinking) {
            Text(message.reasoning)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
        } label: {
            Label(
                message.isStreaming && message.text.isEmpty ? "Thinking…" : "Thought process",
                systemImage: "brain")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

private struct ToolRow: View {
    let tool: ToolActivity
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    if tool.isRunning {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "checkmark.circle")
                            .foregroundStyle(.green)
                            .font(.callout)
                    }
                    if let label = tool.subagentLabel {
                        Text(label)
                            .font(.caption.bold())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.purple.opacity(0.15), in: Capsule())
                    }
                    Text(tool.name).font(.callout.bold())
                    Text(collapsedDetail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    if let duration = tool.durationSeconds {
                        Text(String(format: "%.1fs", duration))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)

            if expanded {
                expandedDetail
            }
        }
        .padding(10)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal)
    }

    private var collapsedDetail: String {
        if tool.isRunning { return tool.context ?? "" }
        return tool.summary ?? tool.context ?? ""
    }

    @ViewBuilder
    private var expandedDetail: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let args = tool.argsText, !args.isEmpty {
                detailBlock("Arguments", args)
            }
            if let diff = tool.inlineDiff, !diff.isEmpty {
                DiffView(diff: diff)
            } else if let result = tool.resultText, !result.isEmpty {
                detailBlock("Result", String(result.prefix(4000)))
            }
        }
    }

    private func detailBlock(_ title: String, _ content: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.bold()).foregroundStyle(.secondary)
            ScrollView(.horizontal) {
                Text(content)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 260)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// +/- colored unified diff.
private struct DiffView: View {
    let diff: String

    var body: some View {
        ScrollView(.horizontal) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(diff.split(separator: "\n", omittingEmptySubsequences: false)
                    .prefix(400).enumerated()), id: \.offset) { _, line in
                    Text(String(line.isEmpty ? " " : line))
                        .font(.caption.monospaced())
                        .foregroundStyle(lineColor(line))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(lineBackground(line))
                }
            }
            .textSelection(.enabled)
        }
        .frame(maxHeight: 320)
    }

    private func lineColor(_ line: Substring) -> Color {
        if line.hasPrefix("+") && !line.hasPrefix("+++") { return .green }
        if line.hasPrefix("-") && !line.hasPrefix("---") { return .red }
        if line.hasPrefix("@@") { return .blue }
        return .primary
    }

    private func lineBackground(_ line: Substring) -> Color {
        if line.hasPrefix("+") && !line.hasPrefix("+++") { return .green.opacity(0.08) }
        if line.hasPrefix("-") && !line.hasPrefix("---") { return .red.opacity(0.08) }
        return .clear
    }
}

private struct NoticeRow: View {
    let notice: SystemNotice

    var body: some View {
        Label(notice.text, systemImage: notice.level == .error
            ? "exclamationmark.triangle" : "info.circle")
            .font(.callout)
            .foregroundStyle(notice.level == .error ? .red : .secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
    }
}

// MARK: - Streaming-safe markdown

/// Renders a (possibly still-growing) markdown string: fenced code blocks
/// become monospaced containers with a copy button; everything else goes
/// through AttributedString's inline markdown (streaming-safe — it never
/// throws on partial input, it just falls back to plain text).
struct MarkdownText: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                switch segment {
                case .prose(let prose):
                    Text(attributed(prose))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                case .code(let code, let language):
                    CodeBlock(code: code, language: language)
                }
            }
        }
    }

    private enum Segment {
        case prose(String)
        case code(String, language: String?)
    }

    /// Split on ``` fences. An unterminated final fence (mid-stream) is
    /// treated as a code block still growing.
    private var segments: [Segment] {
        var result: [Segment] = []
        var remainder = Substring(text)
        while let fenceStart = remainder.range(of: "```") {
            let before = remainder[..<fenceStart.lowerBound]
            if !before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result.append(.prose(String(before)))
            }
            let afterFence = remainder[fenceStart.upperBound...]
            let firstLineEnd = afterFence.firstIndex(of: "\n") ?? afterFence.endIndex
            let language = String(afterFence[..<firstLineEnd])
                .trimmingCharacters(in: .whitespaces)
            let codeStart =
                firstLineEnd < afterFence.endIndex
                ? afterFence.index(after: firstLineEnd) : afterFence.endIndex
            let codeRegion = afterFence[codeStart...]
            if let fenceEnd = codeRegion.range(of: "```") {
                result.append(
                    .code(
                        String(codeRegion[..<fenceEnd.lowerBound])
                            .trimmingCharacters(in: .newlines),
                        language: language.isEmpty ? nil : language))
                remainder = codeRegion[fenceEnd.upperBound...]
            } else {
                // Still streaming inside the fence.
                result.append(
                    .code(
                        String(codeRegion), language: language.isEmpty ? nil : language))
                remainder = Substring("")
            }
        }
        if !remainder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result.append(.prose(String(remainder)))
        }
        return result
    }

    private func attributed(_ string: String) -> AttributedString {
        (try? AttributedString(
            markdown: string,
            options: AttributedString.MarkdownParsingOptions(
                allowsExtendedAttributes: false,
                interpretedSyntax: .inlineOnlyPreservingWhitespace,
                failurePolicy: .returnPartiallyParsedIfPossible)))
            ?? AttributedString(string)
    }
}

private struct CodeBlock: View {
    let code: String
    let language: String?
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language ?? "code")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    copyToPasteboard(code)
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        copied = false
                    }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Copy code")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            ScrollView(.horizontal) {
                Text(code)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
            }
        }
        .background(.quinary, in: RoundedRectangle(cornerRadius: 8))
    }

    private func copyToPasteboard(_ string: String) {
        #if os(macOS)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(string, forType: .string)
        #else
            UIPasteboard.general.string = string
        #endif
    }
}
