# AVA Desktop — Advanced Features

Implement these 7 features for the macOS companion app.

---

## 1. Automated PR Code Review

When the desktop app detects a new PR in a connected GitHub repo (or when triggered by the backend), automatically:
- Clone/pull the repo
- Run `git diff` on the PR branch
- Analyze the changes for bugs, style issues, security concerns
- Post a review comment on the PR via GitHub API

### Implementation
- Create `Handlers/CodeReviewHandler.swift`
- Listen for `desktop_code_review` commands from the backend
- Use `TerminalHandler` to run git commands
- Send the diff to the backend for LLM analysis (POST to chat API with the diff as context)
- Use GitHub API to post review comments (via the user's GitHub connection in Composio)

### Command protocol
```json
{
  "command": "desktop_code_review",
  "action": "review_pr",
  "params": {
    "repo": "owner/repo",
    "prNumber": 42,
    "baseBranch": "main",
    "headBranch": "feature/xyz"
  }
}
```

---

## 3. Codebase Indexing (Deep Repo Understanding)

Index the user's local repositories so agents have deep understanding of their code across sessions.

### Implementation
- Create `Services/CodebaseIndexer.swift`
- On first run (or when user adds a project folder), recursively scan the directory
- For each file: extract language, imports, exports, class/function signatures, comments
- Build a structured index: `{ files: [{ path, language, symbols: [{ name, type, line }] }] }`
- Store the index locally (JSON file in app support directory)
- Send the index to the backend as a knowledge chunk for the agent's context
- Re-index on file changes (use `FSEvents` / `DispatchSource` for file watching)
- Add "Indexed Projects" section in SettingsView with add/remove project folders

### Backend integration
- New command: `desktop_codebase` with actions: `index`, `search`, `get_context`
- `search` returns relevant files/symbols for a query
- `get_context` returns the full content of specific files

### File watcher
```swift
let source = DispatchSource.makeFileSystemObjectSource(
    fileDescriptor: fd,
    eventMask: [.write, .delete, .rename],
    queue: .global()
)
source.setEventHandler { [weak self] in
    self?.reindexProject(at: path)
}
```

---

## 4. Visual Design Mode (Click-to-Edit UI)

When the agent deploys a web app, let the user click on any element to edit its properties visually.

### Implementation
- Create `Views/DesignModeView.swift` — a WKWebView with injected JavaScript
- When the agent deploys a site to a local dev server (via cloud_shell `get_url`), open it in DesignModeView
- Inject CSS/JS that:
  - Highlights elements on hover (blue outline)
  - Shows a property panel on click (font, color, padding, margin, text)
  - Sends edits back to the agent as natural language ("change the header font to 24px bold")
- The agent then modifies the source code accordingly

### Injected JavaScript
```javascript
// Inject into the WKWebView
document.addEventListener('click', (e) => {
    e.preventDefault();
    const el = e.target;
    const styles = window.getComputedStyle(el);
    const info = {
        tag: el.tagName,
        text: el.textContent?.slice(0, 100),
        classes: el.className,
        styles: {
            fontSize: styles.fontSize,
            color: styles.color,
            backgroundColor: styles.backgroundColor,
            padding: styles.padding,
            margin: styles.margin,
        }
    };
    window.webkit.messageHandlers.elementSelected.postMessage(JSON.stringify(info));
}, true);
```

### Property panel
- Show a floating panel next to the selected element
- Text field for quick edits ("Make this bigger", "Change color to blue")
- Send the edit instruction to the backend → agent modifies the code → page hot-reloads

---

## 6. GitHub Repo Import

Let users import an existing GitHub repo so agents can work on it.

### Implementation
- Create `Views/RepoImportView.swift` — a sheet with a text field for repo URL
- Clone the repo to a local directory (~/AVA-Projects/{repoName})
- Index it automatically (use CodebaseIndexer from feature 3)
- Notify the backend that a project is available
- Agent can then use `desktop_file` and `desktop_terminal` to read/modify/run the project

### Flow
1. User pastes repo URL or selects from their GitHub repos (via API)
2. App clones with `git clone` via TerminalHandler
3. Index the project
4. Backend is notified — agents now know about the project
5. User can say "Fix the login bug in my project" and the agent has full context

### New command
```json
{
  "command": "desktop_codebase",
  "action": "import_repo",
  "params": {
    "url": "https://github.com/user/repo.git",
    "branch": "main"
  }
}
```

---

## 9. One-Click MCP Server Installation

Provide a curated list of MCP servers that users can install with one click.

### Implementation
- Create `Views/MCPManagerView.swift` — a list of available MCP servers
- Curated list of popular MCP servers with descriptions:
  - Filesystem (read/write local files)
  - GitHub (repos, issues, PRs)
  - Slack (messages, channels)
  - Google Drive (docs, sheets)
  - Postgres (database queries)
  - Browser (Playwright)
  - Memory (persistent storage)
- Each has an "Install" button that:
  1. Runs `npx -y @modelcontextprotocol/server-{name}` or `uvx mcp-server-{name}`
  2. Configures it in the app's MCP config
  3. Makes it available to agents via the WebSocket relay

### MCP config stored at
`~/Library/Application Support/AVA-Desktop/mcp-servers.json`

### Backend integration
- Desktop advertises available MCP servers in the `hello` frame capabilities
- Agent can call MCP tools through the desktop relay

---

## 10. AI-Assisted Terminal

When the user runs commands in the desktop's terminal, offer AI help.

### Implementation
- Enhance `Handlers/TerminalHandler.swift`
- When a command fails (non-zero exit code), automatically:
  1. Send the command + error output to the agent
  2. Get a suggested fix
  3. Show the suggestion as a notification or inline
- Add a "Ask AI about this" button next to terminal output in the menu bar
- Command: `desktop_terminal` action `explain` — explain what a command does
- Command: `desktop_terminal` action `fix` — suggest a fix for an error

### New terminal actions
```json
{ "action": "explain", "params": { "command": "find . -name '*.py' -exec grep -l 'import os' {} +" } }
{ "action": "fix", "params": { "command": "npm install", "error": "ERESOLVE unable to resolve dependency tree", "exitCode": 1 } }
```

---

## 13. Screen Recording of Agent Work

Record the desktop screen while agents are executing commands, producing a video proof-of-work.

### Implementation
- Create `Services/ScreenRecorder.swift` using `ReplayKit` or `AVCaptureSession`
- When a command sequence starts (multiple commands in a session), automatically start recording
- When the sequence completes, stop recording
- Save the video to a temp directory
- Upload to the backend (S3) and share the URL in the agent's chat
- Agent can reference: "Here's a recording of what I did: [video URL]"

### macOS screen recording
```swift
import ScreenCaptureKit

let filter = SCContentFilter(desktopIndependentWindow: window)
let config = SCStreamConfiguration()
config.width = 1920
config.height = 1080
config.pixelFormat = kCVPixelFormatType_32BGRA

let stream = SCStream(filter: filter, configuration: config, delegate: self)
try await stream.startCapture()
```

### Privacy
- Requires Screen Recording permission (System Settings > Privacy)
- Show a clear indicator when recording is active
- User can disable auto-recording in settings

---

## Key constraints
- SwiftUI only, macOS 14+
- Navy theme (#1A2138)
- All features communicate via the existing WebSocket relay
- New commands should be added to the `CommandCategory` enum or use existing categories
- Use existing handlers where possible (TerminalHandler, FileSystemHandler, etc.)
