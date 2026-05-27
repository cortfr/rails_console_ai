# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

- Skills and memories can now be stored in the database (in addition to the existing on-disk `.rails_console_ai/skills` and `.rails_console_ai/memories` files). DB-backed records are versioned — every save creates a `SkillVersion` / `MemoryVersion` row with `edited_by` and an optional change note
- `SkillLoader#load_all_skills` and `MemoryTools#load_all_memories` now return the union of DB and file records (DB wins on name collision)
- `save_skill` / `save_memory` AI tools accept an optional `target` parameter (`"db"` default, `"file"` to write to disk) plus `change_note`
- New web UI sections at `/rails_console_ai/skills` and `/rails_console_ai/memories` provide list, view, create, edit, delete, version history, side-by-side diff, and restore. File-sourced records are surfaced but read-only in the UI
- `ai_db_setup` / `ai_db_migrate` now create the new `rails_console_ai_skills`, `rails_console_ai_skill_versions`, `rails_console_ai_memories`, and `rails_console_ai_memory_versions` tables idempotently

## [0.29.0]

- Allow steering Slack conversations mid-run by sending follow-up messages that are folded in as user guidance at the next tool-loop boundary
- Propagate steering guidance into sub-agent runs so interruptions are seen by both the main engine and any active sub-agent

## [0.28.0]

- Add `bin/smoke_model.rb` to smoke-test new models (plain, tool, parallel, cache checks)
- Support Claude Opus 4.7 by omitting the `temperature` parameter for models that reject it
- Show both estimated request tokens and total billed tokens in LLM round status
- Auto-upgrade to thinking model on "think harder/deeper/carefully" phrases in Slack as well as console
- Fix cancelled code execution state persisting into the next user turn

## [0.26.0]

- Add sub-agent support
- Add integration tests
- Increase max conversation rounds
- Fix sub-agent model resolution
- Improve plan step failure handling

## [0.25.0]

- Expand truncation limits
- Allow any user on allow list to interact with Slack bot in a thread
- Handle ctrl-c better in console
- Fix stdout capture in Slack sessions
- Improve Slack bot logging
- Fix thread safety issues in Slack bot

## [0.24.0]

- Refactor thinking text display and include in Slack with more technical detail
- Add `a` command to trigger auto-accept mode
- Include code output in Slack server logs
- Fix Bedrock issue after declining code execution
- Fix `allow_code_execution` configuration

## [0.23.0]

- Add `save_skill` tool
- Add targeted single-memory recall to avoid extraneous results
- Summarize memory recall output
- Fix Bedrock blank content handling
- Improve debug output and fix `trim_outputs` in Bedrock provider
- Preserve activated skills in conversation without truncating
- Show executed code in Slack log
- Include columns in `describe_model` to reduce tool calls
- Show less error detail in Slack channel
- Show thinking text before `execute_code` prompt in console
- Allow code execution without safety guards
- Add Slack configuration option to prevent all users from executing code
- Detect LLM tool loops and break out
- Refactor output truncation to fix LLM not seeing all needed outputs
- Show cache usage in `display_usage`
- Fix `recall_output` forcing expansion in later turns
- Fix conversation debug to show "tool_result" instead of "user"
- Make `/context` and `!context` show the same as debug output
- Improve `!context` handling in Slack

## [0.22.0]

- Fix blank content block handling in Bedrock provider
- Fix `recall_output` to expand in place and restore preview after LLM responds, preventing context bloat
- Remove safety guard bypass from prompt
- Fix issue where LLM couldn't recall multiple outputs at once

## [0.21.0]

- Add Slack @mention support and channel name tracking
- Stop looping after user cancels execution
- Remove edit feature from executor
- Include more info in tool call log line
- Support class methods in `bypass_guards_for_methods`
- Rename setup tasks to `ai_db_setup` and `ai_db_migrate`
- Fix effective model resolution in multi-threaded Slack bot
- Fix cost tracking with prompt caching through Bedrock
- Add `/unthink` command
- Make `!think` / `/think` thread-safe for Slack
- Fix truncating console output
- Reduce cost by deferring large output until LLM requests it
- Add `!name`, `!model`, and `/model` commands to Slack and console

## [0.20.0]

- Add per-user system prompt seeding
- Improve explicit code execution through Slack bot
- Show last thinking output before prompting
- Add Skills system
- Add `bypass_guards_for_methods` to allow specific methods to skip safety guards
- Add `execute_code` tool for simple query execution without code fences
- Support `<code>` tags in Slack responses
- Improve Slack bot server logging and keepalive visibility
- Improve database safety guards in Rails 5

## [0.19.0]

- Fix duplicate tool result IDs in AWS Bedrock provider

## [0.18.0]

- Handle "smart" quotes coming from Slack
- Eager load when Slack bot starts up
- Handle `>` in Slack for direct code execution
- Handle stopping of sessions in Slack bot by recording the stop

## [0.17.0]

- Add `/retry` command
- Print provider information when `ai!` starts
- Keep Slack bot alive during long-running sessions
- Improve Slack bot log prefixes for production log search
- Catch safety errors even when swallowed by executed code
- Fix Bedrock handling of multiple tool results

## [0.16.0]

- Run migrations during setup
- Clarify LLM activity messages in Slack channel
- Clean up error messages
- Rotate thinking messages in Slack bot

## [0.15.0]

- Add `config.code_search_paths` to configure searchable code directories

## [0.14.0]

- Change module name from `RailsConsoleAI` to `RailsConsoleAi`

## [0.13.0]

- Rename gem from `console_agent` to `rails_console_ai`
- Add AWS Bedrock provider
- Add prompt caching and cache-aware cost tracking for Anthropic
- Enable prompt caching for Bedrock

## [0.12.0]

- Add `slack_allowed_usernames` to restrict Slack channel access

## [0.11.0]

- Add Slack channel integration with system instructions and connection pooling
- Extract channels abstraction and ConversationEngine from Repl
- Add built-in safety guards with `/danger` bypass and progressive safety allowlists
- Add local model support with prompt truncation warnings
- Add `clear!` command to clear bot messages in thread
- Match code blocks in LLM results
- Fix long query display and add cost tracking to session viewer
- Strip quotes from session names when saving

## [0.10.0]

- Add `/expand` command to view previous results
- Exclude previous output from context; add tool for LLM to retrieve it on demand
- Show summarized info per LLM call in `/debug`

## [0.9.0]

- Add `/system` and `/context` commands to inspect what is being sent
- Omit huge output from tool results
- Don't cancel code execution on incorrect prompt answers
- Preserve code blocks when compacting; require manual `/compact`
- Fix authentication when neither method was applied
- Remove prompt to upgrade model on excessive tool calls

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

- Add core memory (`rails_console_ai.md`) that persists across sessions in the system prompt
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
- Add session logging to DB with `/rails_console_ai` admin UI
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
