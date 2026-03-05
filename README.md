# ConsoleAgent

Claude Code for your Rails Console.

```
irb> ai "find the 5 most recent orders over $100"
  Thinking...
  -> list_tables
     12 tables: users, orders, line_items, products...
  -> describe_table("orders")
     8 columns

  Order.where("total > ?", 100).order(created_at: :desc).limit(5)

Execute? [y/N/edit] y
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
gem 'console_agent', group: :development
```

```bash
bundle install
rails generate console_agent:install
```

Set your API key in the generated initializer or via env var (`ANTHROPIC_API_KEY`):

```ruby
# config/initializers/console_agent.rb
ConsoleAgent.configure do |config|
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
| `ai_setup` | Install session logging table |
| `ai_sessions` | List recent sessions |
| `ai_resume` | Resume a session by name or ID |
| `ai_memories` | Show stored memories |
| `ai_status` | Show current configuration |

### Interactive Mode

`ai!` starts a conversation. Slash commands available inside:

| Command | What it does |
|---------|-------------|
| `/auto` | Toggle auto-execute (skip confirmations) |
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

- **Tool use** — AI introspects your schema, models, files, and code to write accurate queries
- **Multi-step plans** — complex tasks are broken into steps, executed sequentially with `step1`/`step2` references
- **Two-tier models** — defaults to Sonnet for speed/cost; `/think` upgrades to Opus when you need it
- **Cost tracking** — `/cost` shows per-model token usage and estimated spend
- **Memories** — AI saves what it learns about your app across sessions
- **App guide** — `ai_init` generates a guide injected into every system prompt
- **Sessions** — name, list, and resume interactive conversations (`ai_setup` to enable)
- **History compaction** — `/compact` summarizes long conversations to reduce cost and latency
- **Output trimming** — older execution outputs are automatically replaced with references; the LLM can recall them on demand via `recall_output`, and you can `/expand <id>` to see them
- **Debug mode** — `/debug` shows context breakdown, token counts, and per-call cost estimates before and after each LLM call

## Configuration

```ruby
ConsoleAgent.configure do |config|
  config.provider = :anthropic       # or :openai
  config.auto_execute = false         # true to skip confirmations
  config.session_logging = true       # requires ai_setup
  config.model = 'claude-sonnet-4-6'  # model used by /think (default)
  config.thinking_model = 'claude-opus-4-6'  # model used by /think (default)
end
```

The default model is `claude-sonnet-4-6` (Anthropic) or `gpt-5.3-codex` (OpenAI). The thinking model defaults to `claude-opus-4-6` and is activated via `/think` or by saying "think harder".

## Web UI Authentication

The engine mounts a session viewer at `/console_agent`. By default it's open — you can protect it with basic auth or a custom authentication function.

### Basic Auth

```ruby
ConsoleAgent.configure do |config|
  config.admin_username = 'admin'
  config.admin_password = ENV['CONSOLE_AGENT_PASSWORD']
end
```

### Custom Authentication

For apps with their own auth system, pass a proc to `authenticate`. It runs in the controller context, so you have access to `session`, `request`, `redirect_to`, etc.

```ruby
ConsoleAgent.configure do |config|
  config.authenticate = proc {
    user = User.find_by(id: session[:user_id])
    unless user&.admin?
      redirect_to '/login'
    end
  }
end
```

When `authenticate` is set, `admin_username` / `admin_password` are ignored.

## Requirements

Ruby >= 2.5, Rails >= 5.0, Faraday >= 1.0

## License

MIT
