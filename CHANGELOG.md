# Changelog

All notable changes to this project will be documented in this file.

## [0.8.0]

- Add authentication function support so host apps can avoid using basic auth
- Add `/think` and `/cost` commands with Sonnet vs Opus support
- Gracefully handle token limit exceeded errors

## [0.7.0]

- Include binding variables and their classes in the Rails console context
- Add `ai_setup` command
- Add `/compact` mechanism for conversation management
- Catch errors and attempt to auto-fix them

## [0.6.0]

- Add core memory (`console_agent.md`) that persists across sessions in the system prompt
- Add `ai_init` command to seed core memory
- Allow reading partial files
- Fix rspec hanging issues

## [0.5.0]

- Auto-accept single-step plans
- Support `>` shorthand to run code directly
- Add `script/release` for releases

## [0.4.0]

- Fix resuming sessions repeatedly
- Fix terminal flashing/loading in production (kubectl)
- Better escaping during thinking output

## [0.3.0]

- Add plan mechanism with "auto" execution mode
- Add session logging to DB with `/console_agent` admin UI
- List and resume past sessions with pagination
- Add shift-tab for auto-execute mode
- Add usage display and debug toggle
- Store sessions incrementally; improved code segment display

## [0.2.0]

- Add memory system with individual file storage
- Add `ask_user` tool
- Add registry cache
- Fix REPL up-key and ctrl-a navigation
- Show tool usage and model processing info
- Add token count information and debug ability
- Use tools-based approach instead of sending everything at once

## [0.1.0]

- Initial implementation
