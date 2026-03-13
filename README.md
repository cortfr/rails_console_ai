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
- **Safe mode** — configurable guards that block side effects (DB writes, HTTP mutations, email delivery) during AI code execution

## Safety Guards

Safety guards prevent AI-generated code from causing side effects. When a guard blocks an operation, the user is prompted to re-run with safe mode disabled.

### Built-in Guards

```ruby
RailsConsoleAi.configure do |config|
  config.use_builtin_safety_guard :database_writes  # blocks INSERT/UPDATE/DELETE/DROP/etc.
  config.use_builtin_safety_guard :http_mutations    # blocks POST/PUT/PATCH/DELETE via Net::HTTP
  config.use_builtin_safety_guard :mailers           # disables ActionMailer delivery
end
```

- **`:database_writes`** — intercepts the ActiveRecord connection adapter to block write SQL. Works on Rails 5+ with any database adapter.
- **`:http_mutations`** — intercepts `Net::HTTP#request` to block non-GET/HEAD/OPTIONS requests. Covers libraries built on Net::HTTP (HTTParty, RestClient, Faraday).
- **`:mailers`** — sets `ActionMailer::Base.perform_deliveries = false` during execution.

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

Default model: `claude-sonnet-4-6`. Thinking model: `claude-opus-4-6`. Prompt caching is enabled automatically.

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
  # config.model = 'us.anthropic.claude-sonnet-4-6'           # default
  # config.thinking_model = 'us.anthropic.claude-opus-4-6-v1' # default
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
end
```

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
   - `groups:history` (private channels, optional)
   - `im:history` (direct messages)
   - `users:read`

4. **Event Subscriptions** — Event Subscriptions → toggle ON, then under "Subscribe to bot events" add:
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

This starts a long-running process (run it separately from your web server). Each new message creates a session; threaded replies continue the conversation. The bot auto-executes code with safety guards always enabled — there is no `/danger` equivalent in Slack.

## Requirements

Ruby >= 2.5, Rails >= 5.0, Faraday >= 1.0. For Bedrock: `aws-sdk-bedrockruntime` (loaded lazily, not a hard dependency).

## License

MIT
