import HermesKit
import SwiftUI

/// Renders assistant Markdown with support for fenced code blocks and lists.
///
/// SwiftUI's `Text` does not lay out block-level Markdown (lists collapse onto one
/// line, newlines vanish), so we render structure ourselves: split ``` fences via
/// `MarkdownSegment.parse`, then render prose line-by-line — list items get an explicit
/// bullet/number, and each line keeps inline Markdown (bold, code, links).
struct MarkdownText: View {
  let text: String
  /// Token of the code block currently showing the "copied" checkmark (#9). Compared
  /// against each block's per-instance token.
  var copiedToken: String?
  /// Disambiguates this message's code blocks from other messages' (typically the row id).
  var tokenPrefix: String = ""
  /// Invoked with the block's raw text and its token when its copy button is tapped.
  /// When `nil`, no copy button is shown (e.g. previews/snapshots without a store).
  var onCopyCode: ((_ text: String, _ token: String) -> Void)?

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      ForEach(Array(MarkdownSegment.parse(text).enumerated()), id: \.offset) { index, segment in
        switch segment {
        case let .prose(value):
          prose(value)
        case let .image(url, alt):
          MarkdownImageView(url: url, alt: alt)
        case let .heading(level, value):
          heading(level: level, text: value)
        case let .blockquote(value):
          blockquote(value)
        case let .table(headers, rows):
          // Capped columns + horizontal panning live in the dedicated view (#59).
          MarkdownTableView(headers: headers, rows: rows)
        case let .code(value, language):
          let token = "\(tokenPrefix)#\(index)"
          CodeBlockView(
            code: value,
            language: language,
            isCopied: copiedToken == token,
            onCopy: onCopyCode.map { copy in { copy(value, token) } }
          )
        }
      }
    }
    // Offer selection on every rendered text run so any part of an agent response can be
    // copied, not just the per-code-block copy button (which keeps its own
    // `.textSelection`/copy button). (#27b)
    //
    // Only PROSE is guaranteed: it renders through `SelectableText` (a real `UITextView`,
    // which owns gestures the transcript's collection view can't pre-empt). Headings,
    // blockquotes and table cells rely on this modifier, which `SelectableText`'s own doc
    // comment records as unreliable inside that collection view — unverified on device and
    // tracked on #59.
    .textSelection(.enabled)
  }

  /// A contiguous prose block, rendered as one selectable `UITextView` so a long-press
  /// drag-selects any range across the whole block (not just a single line). See
  /// `SelectableText`. List bullets and inline Markdown are baked into the attributed text.
  private func prose(_ value: String) -> some View {
    SelectableText(attributed: ProseAttributedBuilder.make(value))
      .frame(maxWidth: .infinity, alignment: .leading)
  }

  /// An ATX header: scaled bold text, level 1–6 mapping to decreasing font sizes.
  private func heading(level: Int, text: String) -> some View {
    Text(Self.inline(text))
      .font(Self.headingFont(level: level))
      .fontWeight(.bold)
      .frame(maxWidth: .infinity, alignment: .leading)
  }

  private static func headingFont(level: Int) -> Font {
    switch level {
    case 1: return .title
    case 2: return .title2
    case 3: return .title3
    case 4: return .headline
    case 5: return .subheadline
    default: return .callout
    }
  }

  /// A blockquote: an indented secondary-styled block with a leading vertical bar.
  private func blockquote(_ value: String) -> some View {
    let lines = value.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    return HStack(alignment: .top, spacing: 8) {
      Rectangle()
        .fill(Color.secondary.opacity(0.4))
        .frame(width: 3)
      VStack(alignment: .leading, spacing: 3) {
        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
          Text(Self.inline(line))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
    }
    .fixedSize(horizontal: false, vertical: true)
  }

  /// Inline-only Markdown so bold/code/links render but block layout (which `Text`
  /// can't show) is avoided; whitespace is preserved. Shared with `MarkdownTableView`'s
  /// cells so the two cannot drift on parsing options.
  static func inline(_ value: String) -> AttributedString {
    let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
    return (try? AttributedString(markdown: value, options: options)) ?? AttributedString(value)
  }

  /// Classify a line as a list item, returning the marker to show and the content
  /// after it. Handles `-`/`*`/`+` bullets and `N.` ordered items.
  static func listMarker(_ trimmed: String) -> (marker: String, content: String)? {
    for prefix in ["- ", "* ", "+ "] where trimmed.hasPrefix(prefix) {
      return ("•", String(trimmed.dropFirst(prefix.count)))
    }
    // Ordered list: leading digits followed by ". ".
    let digits = trimmed.prefix { $0.isNumber }
    if !digits.isEmpty {
      let rest = trimmed[digits.endIndex...]
      if rest.hasPrefix(". ") {
        return ("\(digits).", String(rest.dropFirst(2)))
      }
    }
    return nil
  }
}

/// A standalone image segment (#image): renders inline over http(s) via `AsyncImage`,
/// or decodes a `data:` URL (the shape the gateway substitutes for `MEDIA:` paths, which
/// the phone can't read from the server's disk) into a `UIImage`. Falls back to the alt
/// text / a small label when nothing loads, so a broken reference never collapses the row.
struct MarkdownImageView: View {
  let url: String
  let alt: String

  @State private var decoded: UIImage?
  @Environment(\.openURL) private var openURL

  var body: some View {
    Group {
      if let decoded {
        Image(uiImage: decoded).resizable().scaledToFit()
      } else if let remote = URL(string: url), url.hasPrefix("http") {
        AsyncImage(url: remote) { phase in
          switch phase {
          case let .success(image): image.resizable().scaledToFit()
          case .failure: fallback
          case .empty: ProgressView()
          @unknown default: fallback
          }
        }
      } else {
        fallback
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .clipShape(.rect(cornerRadius: 12))
    .contentShape(.rect)
    .onTapGesture { if let remote = URL(string: url), url.hasPrefix("http") { openURL(remote) } }
    .task(id: url) { decoded = Self.decodeDataURL(url) }
    .accessibilityLabel(alt.isEmpty ? "Image" : alt)
  }

  private var fallback: some View {
    HStack(spacing: 6) {
      Image(systemName: "photo")
      Text(alt.isEmpty ? url : alt).font(.caption).lineLimit(1)
    }
    .foregroundStyle(.secondary)
    .padding(8)
    .background(Color(uiColor: .tertiarySystemBackground), in: .rect(cornerRadius: 8))
  }

  /// Decode a `data:image/...;base64,...` URL into an image; `nil` for non-data URLs.
  static func decodeDataURL(_ raw: String) -> UIImage? {
    guard raw.hasPrefix("data:"), let comma = raw.firstIndex(of: ",") else { return nil }
    let b64 = String(raw[raw.index(after: comma)...])
    guard let data = Data(base64Encoded: b64, options: .ignoreUnknownCharacters) else { return nil }
    return UIImage(data: data)
  }
}

/// A fenced code block rendered in a monospaced box with an optional per-block copy
/// button (#9). Tapping copy flips the icon to a green checkmark; the parent reducer
/// owns the transient feedback so the checkmark clears on a timer.
struct CodeBlockView: View {
  let code: String
  let language: String?
  let isCopied: Bool
  /// `nil` hides the copy button (previews/snapshots without a store).
  let onCopy: (() -> Void)?

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    Text(code)
      .font(.callout.monospaced())
      .textSelection(.enabled)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(8)
      .background(Color(uiColor: .tertiarySystemBackground), in: .rect(cornerRadius: 8))
      .overlay(alignment: .topTrailing) {
        if let onCopy {
          Button(action: onCopy) {
            Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
              .font(.caption.weight(.medium))
              .foregroundStyle(isCopied ? Color.green : Color.secondary)
              .padding(6)
              .background(.thinMaterial, in: .circle)
          }
          .buttonStyle(.plain)
          .padding(6)
          .accessibilityLabel(isCopied ? "Copied" : "Copy code")
          .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: isCopied)
        }
      }
  }
}
