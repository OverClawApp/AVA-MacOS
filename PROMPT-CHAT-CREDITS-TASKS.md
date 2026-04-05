# AVA Desktop — Chat, Credits & Tasks

Add three new features to the AVA Desktop companion app.

---

## 1. Chat with Orchestrator

Add a mini chat interface in the menu bar popover that lets users message their orchestrator agent directly from the Mac. This is NOT a full chat — it's a quick prompt bar like Spotlight.

### Implementation
- Add a text field at the top of the menu bar popover: "Ask your agents..."
- When the user types and hits Enter, send the message to the orchestrator via the backend API
- Show the streaming response below the input
- Use the existing `AuthStore` for JWT authentication
- API: `POST https://api.overclaw.app/agents/{orchestratorId}/chat` with SSE streaming (same as the iOS app)
- To get the orchestrator ID: `GET https://api.overclaw.app/agents` → find the one with `personality: "orchestrator"`
- Keep last 5 conversations in a scrollable list below the input
- Navy theme matching iOS app

### Reference the iOS implementation
- Read `~/GitHub-iOS/OverClaw/Services/APIClient.swift` — find `streamMessage` to understand the SSE chat API
- Read `~/GitHub-iOS/backend/src/routes/chat.ts` — understand the POST body format: `{ message: string, fileName?: string, fileContent?: string }`
- The response is SSE with `data: {"delta": "text"}` events and `data: {"done": true}` at the end

### UI layout in MenuBarView

```
┌─────────────────────────────┐
│ 🔍 Ask your agents...      │  ← TextField
├─────────────────────────────┤
│ Agent response streams here │  ← Scrollable response area
│ ...                         │
├─────────────────────────────┤
│ ● Connected  │  📊 Credits  │  ← Status bar (existing + new)
├─────────────────────────────┤
│ Recent commands...          │  ← Existing command log
└─────────────────────────────┘
```

---

## 2. Usage / Credits Display

Show the user's credit usage in the menu bar popover.

### Implementation
- Add a "Credits" section below the chat response area
- Fetch from `GET https://api.overclaw.app/stats/usage` (requires JWT auth)
- Show: tier name, credits used / credits limit, percentage bar
- Format credits as "12.4M / 20M" using the same format as iOS
- Refresh every 60 seconds
- Use the existing `AuthStore.accessToken` for auth

### Response format from the API

```json
{
  "offices": [{
    "officeNumber": 1,
    "tier": "premium",
    "creditsUsed": 1234567,
    "creditsLimit": 20000000,
    "monthlyRatio": 0.06
  }]
}
```

---

## 3. Tasks View

Show the user's task board in a section of the menu bar popover.

### Implementation
- Add a "Tasks" section that shows active/scheduled tasks
- Fetch from `GET https://api.overclaw.app/tasks` (requires JWT auth)
- Show: task title, status badge (scheduled/active/completed), assigned agent name
- Tap a task to see details in a detail popover
- "New Task" button that opens a simple task creation sheet (title + description + schedule)
- Create via `POST https://api.overclaw.app/tasks` with body: `{ title, description, agentIds: [orchestratorId], scheduleKind: "at" }`

### Task response format

```json
[{
  "id": "...",
  "title": "Morning briefing",
  "status": "scheduled",
  "scheduleKind": "every",
  "taskPersonas": [{ "persona": { "id": "...", "name": "Jarvis" } }]
}]
```

---

## Key constraints
- All API calls use `AuthStore.accessToken` as Bearer token
- Base URL from `Constants.apiBaseURL` (https://api.overclaw.app)
- Navy theme (#1A2138) matching iOS
- Menu bar popover should be ~320px wide, ~500px tall
- Keep it lightweight — this is a companion, not a full app
- SwiftUI only, macOS 14+

## Files to modify
- `Views/MenuBarView.swift` — add chat input, credits, tasks sections
- Create `Services/APIService.swift` — handles all REST API calls (chat SSE, stats, tasks)
- Create `Views/ChatSection.swift` — the mini chat component
- Create `Views/CreditsSection.swift` — usage display
- Create `Views/TasksSection.swift` — task list + creation
