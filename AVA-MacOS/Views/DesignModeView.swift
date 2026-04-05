import SwiftUI
import WebKit

/// Visual design mode — WKWebView with injected element inspector.
/// Click any element to see its properties and send edit instructions to agents.
struct DesignModeView: View {
    let url: URL
    let onEditRequest: (String) -> Void
    @State private var selectedElement: ElementInfo?
    @State private var editInstruction = ""

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            DesignWebView(url: url) { info in
                selectedElement = info
            }

            // Property panel overlay
            if let element = selectedElement {
                propertyPanel(element)
                    .padding(16)
                    .transition(.move(edge: .trailing))
            }
        }
        .frame(minWidth: 800, minHeight: 600)
    }

    private func propertyPanel(_ element: ElementInfo) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(element.tag)
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.navy)

                if !element.classes.isEmpty {
                    Text(".\(element.classes)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Color.navy.opacity(0.5))
                        .lineLimit(1)
                }

                Spacer()

                Button(action: { selectedElement = nil }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Color.navy.opacity(0.3))
                }
                .buttonStyle(.plain)
            }

            if !element.text.isEmpty {
                Text("\"\(element.text.prefix(60))\"")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.navy.opacity(0.6))
            }

            // Style properties
            VStack(alignment: .leading, spacing: 4) {
                styleRow("Font", element.fontSize)
                styleRow("Color", element.color)
                styleRow("Background", element.backgroundColor)
                styleRow("Padding", element.padding)
                styleRow("Margin", element.margin)
            }

            Divider()

            // Quick edit
            HStack(spacing: 6) {
                TextField("Edit instruction...", text: $editInstruction)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .onSubmit {
                        guard !editInstruction.isEmpty else { return }
                        onEditRequest(editInstruction)
                        editInstruction = ""
                    }

                Button(action: {
                    guard !editInstruction.isEmpty else { return }
                    onEditRequest(editInstruction)
                    editInstruction = ""
                }) {
                    Image(systemName: "arrow.up.circle.fill")
                        .foregroundStyle(Color.navy)
                }
                .buttonStyle(.plain)
            }
            .padding(8)
            .background(Color.navy.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .padding(16)
        .frame(width: 280)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.12), radius: 20, y: 8)
    }

    private func styleRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.navy.opacity(0.4))
                .frame(width: 70, alignment: .trailing)
            Text(value)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Color.navy)
        }
    }
}

// MARK: - Element Info

struct ElementInfo {
    let tag: String
    let text: String
    let classes: String
    let fontSize: String
    let color: String
    let backgroundColor: String
    let padding: String
    let margin: String
}

// MARK: - WKWebView Wrapper

struct DesignWebView: NSViewRepresentable {
    let url: URL
    let onElementSelected: (ElementInfo) -> Void

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: "elementSelected")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onElementSelected: onElementSelected)
    }

    class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        let onElementSelected: (ElementInfo) -> Void

        init(onElementSelected: @escaping (ElementInfo) -> Void) {
            self.onElementSelected = onElementSelected
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // Inject element inspector JS
            let js = """
            (function() {
                let hoverEl = null;
                document.addEventListener('mouseover', function(e) {
                    if (hoverEl) hoverEl.style.outline = '';
                    hoverEl = e.target;
                    hoverEl.style.outline = '2px solid rgba(77, 153, 255, 0.8)';
                }, true);
                document.addEventListener('mouseout', function(e) {
                    if (hoverEl) hoverEl.style.outline = '';
                }, true);
                document.addEventListener('click', function(e) {
                    e.preventDefault();
                    e.stopPropagation();
                    var el = e.target;
                    var styles = window.getComputedStyle(el);
                    var info = {
                        tag: el.tagName,
                        text: (el.textContent || '').slice(0, 100).trim(),
                        classes: el.className || '',
                        fontSize: styles.fontSize,
                        color: styles.color,
                        backgroundColor: styles.backgroundColor,
                        padding: styles.padding,
                        margin: styles.margin
                    };
                    window.webkit.messageHandlers.elementSelected.postMessage(JSON.stringify(info));
                }, true);
            })();
            """
            webView.evaluateJavaScript(js)
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let jsonStr = message.body as? String,
                  let data = jsonStr.data(using: .utf8),
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return }

            let info = ElementInfo(
                tag: dict["tag"] ?? "",
                text: dict["text"] ?? "",
                classes: dict["classes"] ?? "",
                fontSize: dict["fontSize"] ?? "",
                color: dict["color"] ?? "",
                backgroundColor: dict["backgroundColor"] ?? "",
                padding: dict["padding"] ?? "",
                margin: dict["margin"] ?? ""
            )

            Task { @MainActor in
                onElementSelected(info)
            }
        }
    }
}
