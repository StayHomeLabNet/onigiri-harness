# 🍙 Onigiri Harness

## Native macOS Local AI Harness with Apple Foundation Models, Managed GGUF, Hybrid RAG, Decision Lab, and AI CLI Integration

**Onigiri Harness is a native macOS local AI runtime and desktop app providing on-device Apple Intelligence, managed local GGUF models via llama.cpp, hybrid RAG with cited evidence, Decision Model Lab, and headless AI agent CLI orchestration.**

[English](README.md) | [日本語](README.ja.md)

[Overview](#overview) ・ [Key Features](#key-features) ・ [Requirements](#requirements) ・ [Architecture](#architecture) ・ [Quick Start](#quick-start) ・ [Managed Local Models (GGUF)](#managed-local-models-gguf) ・ [AI Tasks & CLI Integration](#ai-tasks-and-cli-integration) ・ [API & Verification](#api-and-verification) ・ [Project Structure](#project-structure) ・ [License](#license)

![version](https://img.shields.io/badge/version-0.7.0-blue)
[![License](https://img.shields.io/badge/license-Apache--2.0-green)](LICENSE)
![platform](https://img.shields.io/badge/platform-macOS%20(Apple%20Silicon)-orange)
![app](https://img.shields.io/badge/app-SwiftUI%20%2F%20Swift-purple)
![models](https://img.shields.io/badge/models-Apple%20Intelligence%20%7C%20GGUF%20%7C%20OpenAI-brightgreen)
[![CI](https://github.com/StayHomeLabNet/onigiri-harness/actions/workflows/ci.yml/badge.svg)](https://github.com/StayHomeLabNet/onigiri-harness/actions/workflows/ci.yml)

[![Ko-fi](https://img.shields.io/badge/Ko--fi-Support%20StayHomeLabNet-ff5e5b?style=for-the-badge&logo=kofi&logoColor=white)](https://ko-fi.com/stayhomelabnet)
[![Buy Me a Coffee](https://img.shields.io/badge/Buy%20Me%20a%20Coffee-Support%20StayHomeLabNet-ffdd00?style=for-the-badge&logo=buymeacoffee&logoColor=black)](https://buymeacoffee.com/stayhomelabnet)

**If Onigiri Harness is useful to you, please consider supporting the project.**

---

## Overview

Onigiri Harness is a native macOS local AI harness and desktop application designed to harness the full power of private, on-device intelligence.
It seamlessly unites Apple Foundation Models (Apple Intelligence), managed local GGUF inference via `llama.cpp`, external servers (LM Studio and Ollama), and autonomous coding agent CLIs (Codex CLI, Google Antigravity CLI, and Claude Code) into a cohesive macOS desktop workspace.

The runtime features hybrid RAG with cited evidence, Agentic RAG with autonomous search query decisions, Decision Model Lab for structured evaluation and calibration, an OpenAI-compatible local Gateway, and a stdio Model Context Protocol (MCP) server. Built entirely in Swift with zero external package dependencies.

Current version: `v0.7.0`

## Architecture

Onigiri Harness separates the UI layer (SwiftUI), an out-of-process server runtime (Network.framework), and the core engine (OnigiriCore).

```text
OnigiriApp (SwiftUI / Native macOS)
    │
    ▼ HTTP / 127.0.0.1:18080 (loopback)
OnigiriServer (Separate process / Network.framework / OpenAI Gateway)
    │
    ├── OnigiriCore
    │     ├── Harness (Provider orchestration & session lifecycle)
    │     ├── RAGManager (Chunking, hybrid search, and agentic decisions)
    │     ├── CodexAgentManager (Codex / Antigravity / Claude Code CLI execution)
    │     ├── ManagedLocalModels (Hugging Face GGUF downloads / llama-server)
    │     ├── DecisionEvaluation (Decision Model Lab / Ollaya integration)
    │     └── DataProtection (Encryption, Keychain, checksummed backup)
    │
    └── ModelProvider / ModelConversationSession
          ├── AppleFoundationModelsProvider (On-device Apple Intelligence)
          ├── ManagedLocalGGUFProvider (llama-server / 127.0.0.1:18181)
          ├── LocalOpenAICompatibleProvider (LM Studio / Ollama)
          └── CLIChatModelProvider (Codex / Antigravity / Claude Code CLI)
```

## Key Features

- **Multi-Provider Support**
  - **Apple Foundation Models**: Native on-device foundation models running completely offline with zero telemetry.
  - **Onigiri Local (GGUF)**: Direct Hugging Face GGUF catalog browsing, downloading, verification, and execution via `llama-server`.
  - **OpenAI-Compatible Local Servers**: Connect to LM Studio or Ollama with zero friction.
  - **CLI Chat Providers**: Chat directly with installed Codex, Google Antigravity (`agy`), or Claude Code CLIs in read-only sandbox mode.
- **Hybrid RAG & Agentic RAG**
  - Drag-and-drop ingestion of plain text, Markdown, and PDF documents or folders.
  - Multi-strategy retrieval combining chunk overlap, title weighting, exact-match bonuses, Japanese 2/3-grams, and `/v1/embeddings` vector similarity.
  - Evidence citations (`[1]`) embedded in responses with one-click chunk inspector sheets.
  - **Agentic RAG**: Models autonomously decide in structured JSON whether document retrieval is necessary, generate targeted search terms, and execute retry searches when initial relevance is weak.
- **Web Research Integration**
  - Built-in browser and detached window support to view, select, and inject live web pages into conversation turns.
  - Native integration with local SearXNG JSON search and Tavily search API.
- **Autonomous AI Tasks & CLI Integration**
  - Launch asynchronous tasks against Codex, Google Antigravity, or Claude Code CLIs.
  - Configurable sandboxing: `read-only` or `workspace-write` (with strict symlink resolution and directory boundary validation).
  - Multi-task concurrency with real-time streaming logs, timeouts, and cancellation.
- **Decision Model Lab**
  - Benchmark and evaluate decision-focused models (Ollaya / TypeSafe / Jev compatible).
  - Multi-model evaluation across labeled datasets measuring Accuracy, Calibration Error, Latency, and Fallback rates.
- **OpenAI-Compatible Gateway & MCP Server**
  - Local gateway at `http://127.0.0.1:18080/v1` serving Chat Completions (streaming SSE and non-streaming).
  - Bundled stdio MCP server (`onigiri-mcp`) allowing external tools (like Claude Code or Codex) to query Onigiri's RAG knowledge base.
- **Evaluation & Regression Testing (`onigiri-eval`)**
  - Suite management, model matrix benchmarks, scheduled daily runs, and automated regression alerts.
  - Headless `onigiri-eval` CLI to enforce RAG accuracy gates in CI workflows.
- **Data Protection & Portability**
  - Checksummed JSON export/import for conversations, profiles, knowledge bases, and tasks.
  - Automatic rollback snapshots before restore. External API keys are stored in the macOS Keychain, never in plaintext.

## Requirements

- **Hardware**: Apple Silicon Mac (M1 or later)
- **Operating System**: macOS 26 or later
- **Developer Tools**: Xcode 26 or later (with first-launch component setup complete)
- **Apple Intelligence**: Enabled with on-device model downloaded (when using Apple Foundation Models)
- **Optional Tools**:
  - `llama.cpp` (`llama-server`): For running local GGUF models (installable via Homebrew)
  - Installed CLIs: Codex CLI, Google Antigravity CLI (`agy`), Claude Code (for AI Tasks and CLI Chat)

## Quick Start

### 1. Clone the Repository and Start the Server

Open Terminal and start the OnigiriServer runtime:

```sh
git clone https://github.com/StayHomeLabNet/onigiri-harness.git
cd onigiri-harness
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift run --scratch-path /tmp/onigiri-harness-build OnigiriServer
```

### 2. Build and Launch the Desktop App

In a second Terminal window, build and open the client app:

```sh
cd onigiri-harness
zsh scripts/build-app.sh
open /tmp/onigiri-harness-build/Onigiri.app
```

> [!NOTE]
> **First-Launch Gatekeeper Unblocking**
> macOS may quarantine locally built unsigned applications. If prompted, run:
> ```sh
> xattr -cr /tmp/onigiri-harness-build/Onigiri.app
> ```

### 3. Basic Usage

- **Chat**: Enter a greeting in the main window and hit `Enter`. Responses stream in real time.
- **Input Controls**: Use `Enter` to send, `Shift + Enter` for newlines. IME composition confirmation `Enter` will not accidentally send.
- **Add Documents (RAG)**: Click "Add Documents / Folder" and choose text, Markdown, or PDF files. Subsequent prompts automatically retrieve relevant passages and display `[1]` citation tags.
- **Switch Languages**: Switch seamlessly between Japanese and English from the application menu (`Onigiri Harness` → `Settings…`).

## Managed Local Models (GGUF)

From `Settings…` → `Local Models`, browse and download public GGUF models from Hugging Face into dedicated Onigiri storage (`Application Support/OnigiriHarness/local-models/models`).

1. **Install Runtime Engine**:
   Local GGUF execution utilizes `llama.cpp`'s `llama-server`. Click "Install via Homebrew" in the settings UI or run:
   ```sh
   brew install llama.cpp
   # Apple Silicon default path: /opt/homebrew/bin/llama-server
   ```
2. **Load Model**:
   After downloading a model from the catalog, click "Load and Use". Onigiri launches `llama-server` on loopback port `127.0.0.1:18181` and switches your chat provider automatically.
3. **Acceptance Benchmarks & Recommendations**:
   Run multilingual acceptance test suites directly against loaded models to record pass rates, latency, and resident set size (RSS). The settings screen recommends the best model suited to your Mac's installed memory.

## External Providers & CLI Chat

### LM Studio & Ollama
- **LM Studio**: Start the LM Studio Local Server and set the provider in Onigiri to `LM Studio` (Base URL: `http://127.0.0.1:1234/v1`).
- **Ollama**: Start `ollama serve` and set the provider in Onigiri to `Ollama` (Base URL: `http://127.0.0.1:11434/v1`).

### CLI Chat Providers
Select installed **Codex CLI**, **Google Antigravity CLI** (`agy`), or **Claude Code** directly as regular chat providers. Leaving Model ID blank uses your account's default model. CLI chat runs inside an isolated, read-only temporary workspace.

## AI Tasks and CLI Integration

From "AI Tasks" in the right sidebar, dispatch headless tasks to Codex, Google Antigravity, or Claude Code:

- **Sandbox Options**:
  - `read-only`: Safe observation and analysis without disk mutations.
  - `workspace-write`: Allows edits exclusively within the selected working directory (enforces symlink resolution and blocks writes outside the target directory).
- Execute multiple tasks in parallel with live streaming logs, task status, and execution times preserved in history.

## Web Research Integration

Incorporate live information such as market rates, stock prices, or news:

- **Built-in / Detached Browser**:
  Open Web Research in the main window or a detached window, browse to any site, and click "Use this page in conversation" to attach it as a reference context for the next turn.
- **SearXNG Integration**:
  Connect directly to a local SearXNG instance (`http://127.0.0.1:8080`, JSON format enabled) to query search results without external tracking.
- **Tavily Integration**:
  Store your Tavily API key securely in the Keychain. Requests requiring live data will search automatically and cite sources beneath the answer.

## OpenAI-Compatible Gateway & MCP Server

### OpenAI-Compatible API
OnigiriServer exposes a standard Chat Completions endpoint at `http://127.0.0.1:18080/v1`:

```sh
curl http://127.0.0.1:18080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "onigiri/current",
    "messages": [{"role": "user", "content": "Hello!"}],
    "stream": false,
    "onigiri": {"ragMode": "agentic"}
  }'
```

### stdio MCP Server (`onigiri-mcp`)
Expose Onigiri's RAG knowledge base to MCP-enabled tools like Claude Code or Codex:

```sh
codex mcp add onigiri-rag -- /tmp/onigiri-harness-build/Onigiri.app/Contents/MacOS/onigiri-mcp
```
Exposes read-only `searchKnowledge` and `getKnowledgeChunk` tools, recording all calls in a local audit log.

## Evaluation & Regression Testing (`onigiri-eval`)

`onigiri-eval` is a standalone CLI tool to measure RAG accuracy, citations, and latency regressions across model or document changes.

```sh
# Run evaluation suite and output Markdown report
swift run onigiri-eval --suite onigiri-rag-evaluation.json --output rag-report.md

# Fail with non-zero exit code on regression (ideal for CI)
swift run onigiri-eval --suite onigiri-rag-evaluation.json \
  --format json --output current-report.json \
  --baseline baseline-report.json --fail-on-regression
```

The desktop app also provides named suite management, model matrix benchmarking, automated daily evaluation runs, and macOS regression notifications.

## Decision Model Lab

Evaluate and benchmark specialized decision and classification models (Ollaya / TypeSafe compatible):
- Test choices, scores, and routing queries across models.
- Run batch evaluations against ground-truth datasets to compute Accuracy, Calibration Error, Average Latency, and Fallback rates.

## API & Verification

Key HTTP endpoints (all loopback `127.0.0.1:18080`):

| Method | Path | Description |
|---|---|---|
| `GET` | `/health` | Server status and active model provider health |
| `GET` / `POST` | `/providers`, `/provider` | List available providers and switch active provider |
| `GET` | `/local-models` | Catalog of downloaded and available GGUF models |
| `POST` | `/local-models/download` | Download a GGUF model from Hugging Face |
| `POST` | `/local-models/load` | Load a GGUF model into `llama-server` |
| `POST` | `/local-models/benchmark` | Execute benchmark acceptance test on loaded model |
| `POST` | `/chat/stream` | Streamed conversation generation (chunked NDJSON) |
| `POST` | `/chat/cancel` | Abort generation in progress |
| `GET` / `POST` | `/knowledge/documents`, `/knowledge/document` | List RAG documents and ingest new content |
| `POST` | `/knowledge/search` | Search knowledge chunks using hybrid retrieval |
| `GET` / `POST` | `/agents/tasks` | Inspect task history and launch new AI CLI tasks |
| `GET` / `POST` | `/v1/models`, `/v1/chat/completions` | OpenAI-compatible Chat Completions API |

> [!IMPORTANT]
> **Security Requirements for External Exposure**
> If exposing OnigiriServer beyond loopback (e.g., LAN), you must specify `ONIGIRI_SERVER_HOST=0.0.0.0`, `ONIGIRI_ALLOW_EXTERNAL=1`, and a high-entropy `ONIGIRI_API_TOKEN`. Every request must include `Authorization: Bearer <token>`.

## Project Structure

- `Sources/OnigiriApp`: SwiftUI macOS desktop application
- `Sources/OnigiriServer`: Network.framework HTTP / NDJSON server and OpenAI-compatible Gateway
- `Sources/OnigiriCore`: Provider abstraction, RAG engine, GGUF management, AI task adapters, and security logic
- `Sources/OnigiriMCP`: stdio Model Context Protocol (MCP) server
- `Sources/OnigiriEvalCLI`: Headless regression testing CLI (`onigiri-eval`)
- `Tests/OnigiriCoreTests`: Unit and integration test suites
- `scripts/`: Packaging, checking, and release automation scripts

## Security & Distribution Policy

- **Apache License 2.0**: The source code is openly published under the Apache-2.0 license.
- **Local Source Builds**: During periods where the maintainer is not enrolled in the Apple Developer Program, pre-built unsigned macOS application binaries are not distributed via GitHub Releases. Users clone the repository and build locally using the included scripts.
- **Data Privacy**: All conversation logs, documents, and evaluation datasets remain strictly local to your Mac. No data is sent to external networks unless you explicitly select an external provider or search service. Sensitive API credentials are protected via the macOS Keychain.

## License

This project is licensed under the [Apache License 2.0](LICENSE).

All trademarks, external models (Hugging Face, Apple Foundation Models), external CLIs (Codex, Google Antigravity, Claude Code), and third-party services (LM Studio, Ollama, Tavily, SearXNG) are property of their respective owners.
