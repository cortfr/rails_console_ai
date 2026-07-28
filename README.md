# RailsConsoleAi

Claude Code for your Rails Console.

```
irb> ai "find the 5 most recent orders over $100"
  Thinking...
  -> list_tables
     12 tables: users, orders, line_items, products...
  -> describe_table("orders")
     8 columns

  Order.where("total > ?", 100).order(created_at: :desc).limit(5)

Execute? [y/N/danger] y
=> [#<Order id: 4821, ...>, ...]
```

For complex tasks it builds multi-step plans, executing each step sequentially:

```
ai> get the most recent salesforce token and count events via the API
  Plan (2 steps):
  1. Find the most recent active Salesforce OAuth2 token
     token = Oauth2Token.where(provider: "salesforce", active: true)
                        .order(updated_at: :desc).first
  2. Query event count via SOQL
     api = SalesforceApi.new(step1)
     api.query("SELECT COUNT(Id) FROM Event")

  Accept plan? [y/N/a(uto)] a
```

No context needed from you — it figures out your app on its own.

## Install

```ruby
# Gemfile
gem 'rails_console_ai', group: :development
```

```bash
bundle install
rails generate rails_console_ai:install
```

Set your API key in the generated initializer or via env var (`ANTHROPIC_API_KEY`):

```ruby
# config/initializers/rails_console_ai.rb
RailsConsoleAi.configure do |config|
  config.api_key = 'sk-ant-...'
end
```

## Commands

| Command | What it does |
|---------|-------------|
| `ai "query"` | Ask, review generated code, confirm execution |
| `ai!` | Enter interactive mode (multi-turn conversation) |
| `ai? "query"` | Explain only, no execution |
| `ai_init` | Generate app guide for better AI context |
| `ai_db_setup` | Install session logging table + run migrations |
| `ai_db_migrate` | Run pending session table migrations |
| `ai_sessions` | List recent sessions |
| `ai_resume` | Resume a session by name or ID |
| `ai_memories` | Show stored memories |
| `ai_status` | Show current configuration |

### Interactive Mode

`ai!` starts a conversation. Slash commands available inside:

| Command | What it does |
|---------|-------------|
| `/auto` | Toggle auto-execute (skip confirmations) |
| `/danger` | Toggle safe mode off/on (allow side effects) |
| `/safe` | Show safety guard status |
| `/compact` | Compress history into a summary (saves tokens) |
| `/usage` | Show token stats |
| `/cost` | Show per-model cost breakdown |
| `/think` | Upgrade to thinking model (Opus) for the rest of the session |
| `/debug` | Toggle debug summaries (context stats, cost per call) |
| `/expand <id>` | Show full omitted output |
| `/context` | Show conversation history as sent to the LLM |
| `/system` | Show the system prompt |
| `/name <label>` | Name the session for easy resume |

Prefix input with `>` to run Ruby directly (no LLM round-trip). The result is added to conversation context.

Say "think harder" in any query to auto-upgrade to the thinking model for that session. After 5+ tool rounds, you'll also be prompted to switch.

## Features

- **Tool use** — AI introspects your schema, models, files (Ruby, ERB, HTML, JS, CSS, YAML, etc), and code to write accurate queries
- **Multi-step plans** — complex tasks are broken into steps, executed sequentially with `step1`/`step2` references
- **Two-tier models** — defaults to Sonnet for speed/cost; `/think` upgrades to Opus when you need it
- **Cost tracking** — `/cost` shows per-model token usage and estimated spend
- **Skills** — predefined procedures with guard bypasses that the AI activates on demand
- **Memories** — AI saves what it learns about your app across sessions
- **App guide** — `ai_init` generates a guide injected into every system prompt
- **Sessions** — name, list, and resume interactive conversations (`ai_db_setup` to enable)
- **History compaction** — `/compact` summarizes long conversations to reduce cost and latency
- **Output trimming** — older execution outputs are automatically replaced with references; the LLM can recall them on demand via `recall_output`, and you can `/expand <id>` to see them
- **Debug mode** — `/debug` shows context breakdown, token counts, and per-call cost estimates before and after each LLM call
- **Sub-agents** — delegate multi-step investigations to a separate LLM context that returns only a concise summary, keeping the main conversation lean
- **Safe mode** — configurable guards that block side effects (DB writes, HTTP mutations, email delivery) during AI code execution

## Sub-Agents

Sub-agents solve the context bloat problem. When the AI needs to investigate something (find a user's shard, explore model relationships, search code), those intermediate tool calls can inflate the main conversation to 90K+ tokens, causing the LLM to cut corners. Sub-agents fork the investigation into a separate LLM conversation and return only a concise summary.

The AI decides when to use sub-agents via the `delegate_task` tool. It can target a custom agent by name or use a general-purpose investigation.

### Custom Agents

Define agents as markdown files in `.rails_console_ai/agents/`:

```markdown
---
name: Find shard
description: Given a user ID, determines which database shard they are on
max_rounds: 5
tools:
  - execute_code
  - recall_memory
---

You are a shard finder for a sharded Rails application.

Steps:
1. Find the user: User.find(id)
2. Check user.shard
3. Report: "User {username} (ID {id}) is on shard {shard}."
```

**Frontmatter fields:**

| Field | Required | Description |
|-------|----------|-------------|
| `name` | yes | Agent name (shown in system prompt, used with `delegate_task`) |
| `description` | yes | One-line description of what this agent does |
| `max_rounds` | no | Max tool-use rounds (default: `sub_agent_max_rounds` config, default 15) |
| `model` | no | Model override (e.g. use Haiku for simple lookups) |
| `tools` | no | Array of tool names to include (default: all sub-agent tools) |

The markdown body becomes additional system prompt instructions for the sub-agent.

### How It Works

1. Agent summaries appear in the AI's system prompt under `## Agents`
2. The AI calls `delegate_task(task: "find user 56653's shard", agent: "Find shard")`
3. A sub-agent spins up with its own context, tools, and provider
4. It runs the investigation (up to `max_rounds` tool calls)
5. The main conversation receives only: `"Sub-agent result: User 56653 is on shard 5."`

Sub-agents have access to read-only memory tools (`recall_memory`, `recall_memories`), code execution (`execute_code`), and all schema/code introspection tools. They cannot ask the user questions, write memories, or spawn further sub-agents.

### Configuration

```ruby
RailsConsoleAi.configure do |config|
  config.sub_agent_max_rounds = 15         # default max rounds per sub-agent
  config.sub_agent_model = nil             # nil = same model as main conversation
  # config.sub_agent_model = 'claude-haiku-4-5-20251001'  # use a cheaper model
end
```

## Safety Guards

Safety guards prevent AI-generated code from causing side effects. When a guard blocks an operation, the user is prompted to re-run with safe mode disabled.

### Built-in Guards

```ruby
RailsConsoleAi.configure do |config|
  config.use_builtin_safety_guard :database_writes      # blocks INSERT/UPDATE/DELETE/DROP/etc.
  config.use_builtin_safety_guard :http_mutations        # blocks POST/PUT/PATCH/DELETE via Net::HTTP
  config.use_builtin_safety_guard :mailers               # disables ActionMailer delivery
  config.use_builtin_safety_guard :in_process_requests   # blocks in-process requests against the app itself
end
```

- **`:database_writes`** — intercepts the ActiveRecord connection adapter to block write SQL. Works on Rails 5+ with any database adapter.
- **`:http_mutations`** — intercepts `Net::HTTP#request` to block non-GET/HEAD/OPTIONS requests. Covers libraries built on Net::HTTP (HTTParty, RestClient, Faraday).
- **`:mailers`** — sets `ActionMailer::Base.perform_deliveries = false` during execution.
- **`:in_process_requests`** — blocks `ActionDispatch::Integration::Session` requests (the console `app` helper) and direct Rack dispatch (`Rails.application.call`). These run the app's full middleware stack inside the current process and can deadlock or hang the session thread indefinitely, so **all verbs are blocked, including GET**. Allowlist entries are request paths.

### Custom Guards

Write your own guards using the around-block pattern:

```ruby
RailsConsoleAi.configure do |config|
  config.safety_guard :jobs do |&execute|
    Sidekiq::Testing.fake! { execute.call }
  end
end
```

Raise `RailsConsoleAi::SafetyError` in your app code to trigger the safe mode prompt:

```ruby
raise RailsConsoleAi::SafetyError, "Stripe charge blocked"
```

### Allowing Specific Methods

Some operations (like admin approvals) need to write to the database even when guards are active. Use `bypass_guards_for_methods` to declare methods that should bypass all safety guards when called during an AI session:

```ruby
RailsConsoleAi.configure do |config|
  # Global — applies to all channels
  config.bypass_guards_for_methods = [
    'ChangeApproval#approve_by!',
    'ChangeApproval#reject_by!'
  ]

  # Per-channel — only active in the specified channel
  config.channels = {
    'slack'   => { 'bypass_guards_for_methods' => ['Deployment#promote!'] },
    'console' => {}
  }
end
```

Global and channel-specific methods are merged for the active channel. These method shims are installed lazily on the first AI execution (not at boot) and are session-scoped — they only bypass guards inside `SafetyGuards#wrap`. Outside of an AI session (e.g. in normal web requests), the methods behave normally with zero overhead beyond a single thread-local read.

The AI is told about these trusted methods in its system prompt and will use them directly without triggering safety errors.

### Skills

Skills bundle a step-by-step recipe with guard bypass declarations into a single file. Unlike `bypass_guards_for_methods` (which is always-on), skill bypasses are only active after the AI explicitly activates the skill.

Create markdown files in `.rails_console_ai/skills/`:

```markdown
---
name: Approve/Reject ChangeApprovals
description: Approve or reject change approval records on behalf of an admin
tags:
  - change-approval
  - admin
bypass_guards_for_methods:
  - "ChangeApproval#approve_by!"
  - "ChangeApproval#reject_by!"
---

## When to use
Use when the user asks to approve or reject a change approval.

## Recipe
1. Find the ChangeApproval by ID or search
2. Confirm approve or reject
3. Get optional review notes
4. Determine which admin user is acting
5. Call approve_by! or reject_by!

## Code Examples

    ca = ChangeApproval.find(id)
    admin = User.find_by!(email: "admin@example.com")
    ca.approve_by!(admin, "Approved per request")
```

**How it works:**

1. Skill summaries (name + description) appear in the AI's system prompt
2. When the user's request matches a skill, the AI calls `activate_skill` to load the full recipe
3. The skill's `bypass_guards_for_methods` are added to the active bypass set
4. The AI follows the recipe, executing code with the declared methods bypassing safety guards

Skills and global `bypass_guards_for_methods` coexist — use config-level bypasses for simple trusted methods, and skills for operations that benefit from a documented procedure.

### Toggling Safe Mode

- **`/danger`** in interactive mode toggles all guards off/on for the session
- **`d`** at the `Execute? [y/N/danger]` prompt disables guards for that single execution
- When a guard blocks an operation, the user is prompted: `Re-run with safe mode disabled? [y/N]`

## LLM Providers

RailsConsoleAi supports four LLM providers. Each uses a two-tier model system: a default model for speed/cost, and a thinking model activated via `/think` or by saying "think harder".

### Anthropic (default)

```ruby
RailsConsoleAi.configure do |config|
  config.provider = :anthropic
  config.api_key = 'sk-ant-...'  # or set ANTHROPIC_API_KEY env var
end
```

Default model: `claude-sonnet-5`. Thinking model: `claude-opus-5`. Prompt caching is enabled automatically.

### OpenAI

```ruby
RailsConsoleAi.configure do |config|
  config.provider = :openai
  config.api_key = 'sk-...'  # or set OPENAI_API_KEY env var
end
```

Default model: `gpt-5.3-codex`. OpenAI applies prompt caching automatically on their end for prompts over 1024 tokens.

### AWS Bedrock

Access frontier models (Claude, Mistral, DeepSeek, Llama) via your AWS account with pay-per-token pricing. No API key needed — authentication uses the AWS SDK credential chain (IAM roles, env vars, `~/.aws/credentials`).

```ruby
# Gemfile
gem 'aws-sdk-bedrockruntime'
```

```ruby
RailsConsoleAi.configure do |config|
  config.provider = :bedrock
  config.bedrock_region = 'us-east-1'
  # config.model = 'us.anthropic.claude-sonnet-5'        # default
  # config.thinking_model = 'us.anthropic.claude-opus-5'   # default
end
```

Bedrock model IDs use the `us.` prefix for cross-region inference profiles (required for on-demand Anthropic models). Non-Anthropic models use their bare ID:

```ruby
config.model = 'mistral.devstral-2-123b'
config.model = 'deepseek.v3.2'
```

**Setup checklist:**
1. Add `aws-sdk-bedrockruntime` to your Gemfile (it is not a hard dependency of the gem)
2. Ensure AWS credentials are available to the SDK (env vars, IAM role, or `~/.aws/credentials`)
3. For Anthropic models, submit the use case form in the Bedrock console (one-time, per account)
4. The IAM role/user needs `bedrock:InvokeModel` permission

Prompt caching is automatically enabled for Anthropic models on Bedrock, reducing cost on multi-turn tool use conversations.

### Local (Ollama / vLLM / OpenAI-compatible)

Run against a local model server. No API key required.

```ruby
RailsConsoleAi.configure do |config|
  config.provider = :local
  config.local_url = 'http://localhost:11434'
  config.local_model = 'qwen2.5:7b'
  # config.local_api_key = nil  # if your server requires auth
end
```

Timeout is automatically raised to 300s minimum for local models to account for slower inference.

### Testing a new model

Before adopting a new Claude model, smoke-test it against the Anthropic or Bedrock provider with `bin/smoke_model.rb`. The script runs four checks and exits non-zero on any failure:

| check    | what it verifies                                                                 |
| -------- | -------------------------------------------------------------------------------- |
| plain    | the model returns text for a basic prompt                                        |
| tool     | a single tool call → tool result → final answer round-trip works                 |
| parallel | the model issues multiple tool calls in one response when asked                  |
| cache    | a long system prompt is written to and read from the prompt cache (with retry)  |

```bash
# Anthropic — provider inferred from the `claude-` prefix
ANTHROPIC_API_KEY=sk-ant-... bin/smoke_model.rb --model claude-opus-4-8

# Bedrock — provider inferred from the regional `us.anthropic.` prefix.
# Requires the aws-sdk-bedrockruntime gem and AWS credentials in the environment.
bin/smoke_model.rb --model us.anthropic.claude-opus-4-8

# Bedrock in another region
bin/smoke_model.rb --model eu.anthropic.claude-opus-4-8 --region eu-west-1

# Subset of checks, e.g. when iterating on cache behavior
bin/smoke_model.rb --model claude-sonnet-5 --checks cache

# Force a provider when the model ID is ambiguous
bin/smoke_model.rb --provider anthropic --model claude-opus-4-8
```

`DEBUG=1` enables the providers' raw request/response logging.

Pricing, default max tokens, and parameter support (e.g. which families reject `temperature`) are keyed by model family in `Configuration::MODEL_FAMILIES` (`lib/rails_console_ai/configuration.rb`). Family matching is by substring, so one entry covers bare IDs, dated snapshots, and Bedrock inference profiles (`us.` / `global.` prefixes). When adopting a new model family, add an entry there and smoke-test it.

## Configuration

```ruby
RailsConsoleAi.configure do |config|
  config.provider = :anthropic       # :anthropic, :openai, :bedrock, :local
  config.auto_execute = false         # true to skip confirmations
  config.session_logging = true       # requires ai_db_setup
  config.temperature = 0.2
  config.timeout = 30                 # HTTP timeout in seconds
  config.max_tool_rounds = 200        # safety cap on tool-use loops
  config.code_search_paths = %w[app]  # directories for list_files / search_code

  # Runaway-loop circuit breakers (see "Runaway sessions" below)
  config.token_nudge_threshold = 500_000    # input tokens in one tool loop → nudge model to wrap up (nil disables)
  config.token_stop_threshold  = 1_000_000  # input tokens in one tool loop → force a final answer (nil disables)
end
```

### Runaway sessions & known-issue hints

Two mechanisms stop the LLM from burning tokens on a dead end:

**Known-issue hints** — when executed code fails (or prints a rescued error) matching a
known environment-level problem, the tool result includes explicit guidance telling the
model not to retry. The built-in hint recognizes decryption failures
(`OpenSSL::Cipher::CipherError` / "bad decrypt" / `ActiveRecord::Encryption` errors),
which indicate a missing or placeholder encryption key in the console process — an
environment issue no amount of retrying can fix. Repeat occurrences escalate the message.
Apps can add their own:

```ruby
RailsConsoleAi.configure do |config|
  config.error_hints << {
    name: :vpn_required,
    pattern: /Errno::ECONNREFUSED.*10\.8\./,
    hint: "This host is only reachable over the VPN, which this console does not have. " \
          "Do not retry; report the limitation to the user."
  }
end
```

**Circuit breakers** — inside a single tool loop, the engine tracks:

- *Identical tool calls* (same tool + same args): warns at 3, breaks at 5.
- *Repeated error signatures* (same normalized error from **different** code): warns at 3,
  breaks at 5. This catches "new code, same dead end" loops that identical-call detection
  misses. Digits are normalized so varying record IDs don't disguise the same failure.
- *Token budget*: at `token_nudge_threshold` cumulative input tokens the model is told to
  wrap up; at `token_stop_threshold` the loop is stopped and a final answer is forced.

When any breaker trips, the model is asked to summarize what it established, what it
could not determine and why, and what a human should do next — instead of iterating.

### Code Search Paths

By default, `list_files` and `search_code` only look in `app/`. If your project has code in other directories (e.g. a frontend in `public/portal`, or shared code in `lib`), add them:

```ruby
RailsConsoleAi.configure do |config|
  config.code_search_paths = %w[app lib public/portal]
end
```

The tools search all configured paths when no explicit directory is passed. You can still pass a specific directory to either tool to override this.

## Web UI Authentication

The engine mounts a session viewer at `/rails_console_ai`. By default it's open — you can protect it with basic auth or a custom authentication function.

### Basic Auth

```ruby
RailsConsoleAi.configure do |config|
  config.admin_username = 'admin'
  config.admin_password = ENV['CONSOLE_AGENT_PASSWORD']
end
```

### Custom Authentication

For apps with their own auth system, pass a proc to `authenticate`. It runs in the controller context, so you have access to `session`, `request`, `redirect_to`, etc.

```ruby
RailsConsoleAi.configure do |config|
  config.authenticate = proc {
    user = User.find_by(id: session[:user_id])
    unless user&.admin?
      redirect_to '/login'
    end
  }
end
```

When `authenticate` is set, `admin_username` / `admin_password` are ignored.

## Additional Channels

RailsConsoleAi can run through different channels beyond the Rails console. Each channel is a separate process that connects the same AI engine to a different interface.

### Slack

Run RailsConsoleAi as a Slack bot. Each Slack thread becomes an independent AI session with full tool use, multi-step plans, and safety guards always on.

#### Slack App Setup

1. Create a new app at https://api.slack.com/apps → **Create New App** → **From scratch**

2. **Enable Socket Mode** — Settings → Socket Mode → toggle ON. Generate an App-Level Token with the `connections:write` scope. Copy the `xapp-...` token.

3. **Bot Token Scopes** — OAuth & Permissions → Bot Token Scopes, add:
   - `chat:write`
   - `channels:history` (public channels)
   - `channels:read` (channel names in logs, optional)
   - `groups:history` (private channels, optional)
   - `groups:read` (private channel names in logs, optional)
   - `im:history` (direct messages)
   - `users:read`

4. **Event Subscriptions** — Event Subscriptions → toggle ON, then under "Subscribe to bot events" add:
   - `app_mention` (respond when @mentioned in any channel)
   - `message.channels` (public channels)
   - `message.groups` (private channels, optional)
   - `message.im` (direct messages)

5. **App Home** — Show Tabs → toggle **Messages Tab** ON and check **"Allow users to send Slash commands and messages from the messages tab"**

6. **Install to workspace** — Install App → Install to Workspace. Copy the `xoxb-...` Bot User OAuth Token.

7. **Invite the bot** to a channel with `/invite @YourBotName`, or DM it directly.

#### Configuration

```ruby
RailsConsoleAi.configure do |config|
  config.slack_bot_token = ENV['SLACK_BOT_TOKEN']   # xoxb-...
  config.slack_app_token = ENV['SLACK_APP_TOKEN']    # xapp-...

  # Optional: restrict to specific Slack channel IDs
  # config.slack_channel_ids = 'C1234567890,C0987654321'

  # Required: which users the bot responds to (by display name)
  config.slack_allowed_usernames = ['alice', 'bob']  # or 'ALL' for everyone
end
```

#### Running

```bash
bundle exec rake rails_console_ai:slack
```

This starts a long-running process (run it separately from your web server). The bot auto-executes code with safety guards always enabled — there is no `/danger` equivalent in Slack.

**@mention behavior:**
- **DMs** — the bot responds to all messages, no @mention needed.
- **Channels** — the bot only responds when @mentioned. @mention it in any channel message or thread to start a session. The person who first @mentions the bot owns the session — only they can continue the conversation, and they must @mention the bot on each message. Exception: when the bot asks a question, the owner can reply without @mentioning.
- **Joining threads** — when @mentioned mid-thread, the bot reads the thread history for context so it understands what's already been discussed.

## Background Agents

Fire off agent runs from your application code and pick up the result later. Useful when you want to delegate a question (or a multi-step task) to the AI from a controller action, a job, a webhook handler, or any place where blocking on an LLM round-trip is undesirable.

```ruby
id = RailsConsoleAi.run_agent("How many users signed up yesterday?", name: 'daily-stats', user_name: 'cron')
# => 4821 (Integer session id, returned immediately)

RailsConsoleAi.check_agent(id)
# => 'queued' | 'running' | 'ready' | 'failed' | 'aborted' | nil

RailsConsoleAi.get_agent_response(id)
# => { status: 'ready', result: "1,432 users signed up yesterday.\n", error: nil }

RailsConsoleAi.abort_agent(id)
# => true (aborted) | false (already finished, or unknown id)
```

`abort_agent` cancels a run: a queued run is never picked up, and a run already executing keeps going but its result is discarded when it completes -- the session stays `status='aborted'`.

`run_agent` enqueues a row in the sessions table with `mode='agent_api'` and `status='queued'`. A separate long-running rake task picks them up and runs each in its own thread using the same engine that powers `ai "..."` in the console.

### Per-run options

`run_agent` accepts two extra keyword arguments to tune individual runs:

```ruby
RailsConsoleAi.run_agent(
  "Trace why nightly billing is double-charging some accounts",
  use_thinking_model: true,        # run on the thinking-tier model (e.g. Opus)
  max_wall_clock_seconds: 1800     # hard kill after 30 minutes; pass nil for no cap
)
```

- `use_thinking_model:` (default `false`) — switches the run to `config.thinking_model` (or the provider default thinking model) for the duration of the agent. Useful for harder, multi-step problems.
- `max_wall_clock_seconds:` (default `600`) — hard ceiling on wall-clock time. If the run exceeds the cap, the worker thread is killed and the session is marked `status='failed'` with `error_message: "exceeded max_wall_clock_seconds (Ns)"`. Pass `nil` to opt out of any cap.

These (along with any future per-run options) are stored in a JSON `options` column on the session row, so they survive the handoff to the background runner.

### Running the background runner

```bash
bundle exec rake rails_console_ai:agents
# AGENT_CONCURRENCY=3 by default; bump it for more parallelism
AGENT_CONCURRENCY=8 bundle exec rake rails_console_ai:agents
```

The background runner polls every 2 seconds, claims queued rows atomically (only one worker wins a row), and updates each row to `status='ready'` with the result, or `status='failed'` with an error message. SIGINT/SIGTERM triggers a graceful drain — up to 60 seconds for in-flight jobs, then any stragglers are marked `failed`.

Run it separately from your web server, alongside (or instead of) the Slack bot. If the process crashes mid-job, rows stuck in `status='running'` are left as-is — no built-in reaper yet.

### Requirements

- `RailsConsoleAi.setup!` must have been run so the sessions table has the `status`, `result`, `error_message`, and `options` columns. `ai_db_setup` (or `ai_db_migrate` on existing installs) handles this.
- `session_logging` must be enabled (it is by default).

### Behavior notes

- The agent runs with `Channel::Api`, a non-interactive channel — `prompt` returns `''` and `confirm` auto-yes, so the agent never blocks waiting for human input. Safety guards are always on (`supports_danger?` is `false`), and `bypass_guards_for_methods` still applies as usual.
- `result` is composed from the agent's prose answer plus the inspected return value of any code it executed:

  ```
  Let me query the users table for signups from yesterday.

  Result: 1432
  ```

  If the agent answers without running code, you get just the prose. The raw code, its stdout, and the raw return value also live on the session row as `code_executed` / `code_output` / `code_result` if you need them.
- The queue row and the result row are the same row, so the existing session viewer at `/rails_console_ai` shows background runs alongside REPL and Slack sessions.

## Requirements

Ruby >= 2.5, Rails >= 5.0, Faraday >= 1.0. For Bedrock: `aws-sdk-bedrockruntime` (loaded lazily, not a hard dependency).

## License

MIT
