RailsConsoleAi.configure do |config|
  # LLM provider: :anthropic, :openai, or :local
  config.provider = :anthropic

  # API key (or set ANTHROPIC_API_KEY / OPENAI_API_KEY env var)
  # config.api_key = 'sk-...'

  # Model override (defaults: claude-sonnet-5 for Anthropic, gpt-5.3-codex for OpenAI)
  # config.model = 'claude-opus-4-8'

  # Max tokens for LLM response (default resolves per model family; 16000 for Claude models)
  # config.max_tokens = 4096

  # Temperature (0.0 - 1.0)
  config.temperature = 0.2

  # Auto-execute generated code without confirmation (use with caution!)
  config.auto_execute = false

  # Max tool-use rounds per query (safety cap)
  config.max_tool_rounds = 10

  # HTTP timeout in seconds
  config.timeout = 30

  # Local model provider (Ollama, vLLM, or any OpenAI-compatible server):
  # config.provider = :local
  # config.local_url = 'http://localhost:11434'
  # config.local_model = 'qwen2.5:7b'
  # config.local_api_key = nil

  # Slack: which users the bot responds to (legacy — prefer channels config below)
  # config.slack_allowed_usernames = ['alice', 'bob']

  # AWS Bedrock provider (uses AWS credential chain — no API key needed):
  # config.provider = :bedrock
  # config.bedrock_region = 'us-east-1'
  # config.model = 'us.anthropic.claude-sonnet-5'

  # Debug mode: prints full API requests/responses and tool calls to stderr
  # config.debug = true

  # Session logging: persist AI sessions to the database
  # Run RailsConsoleAi.setup! in the Rails console to create the table
  config.session_logging = true

  # Database connection for RailsConsoleAi tables (default: ActiveRecord::Base)
  # Set to a class that responds to .connection if tables live on a different DB
  # config.connection_class = Sharding::CentralizedModel

  # Admin UI credentials (mount RailsConsoleAi::Engine => '/rails_console_ai' in routes.rb)
  # When nil, all requests are denied. Set credentials or use config.authenticate.
  # config.admin_username = 'admin'
  # config.admin_password = 'changeme'

  # Safety guards: prevent side effects (DB writes, HTTP calls, etc.) during code execution.
  # When enabled, code runs in safe mode by default. Users can toggle with /danger in the REPL.
  #
  # Built-in guard for database writes (works on Rails 5+, all adapters):
  # config.use_builtin_safety_guard :database_writes
  #
  # Built-in guard for HTTP mutations — blocks POST/PUT/PATCH/DELETE via Net::HTTP.
  # Covers most Ruby HTTP libraries (HTTParty, RestClient, Faraday) since they use Net::HTTP:
  # config.use_builtin_safety_guard :http_mutations
  #
  # Allowlist specific hosts or tables so they pass through without blocking:
  # config.use_builtin_safety_guard :http_mutations,
  #   allow: [/s3\.amazonaws\.com/, /googleapis\.com/]
  # config.use_builtin_safety_guard :database_writes,
  #   allow: ['rails_console_ai_sessions']
  #
  # Built-in guard for mailers — disables ActionMailer delivery:
  # config.use_builtin_safety_guard :mailers
  #
  # Built-in guard for in-process requests — blocks ActionDispatch::Integration::Session
  # (the console `app` helper) and direct Rack dispatch against the running app.
  # These run the full middleware stack inside this process and can hang the session
  # thread indefinitely, so ALL verbs are blocked (including GET). Strongly recommended
  # for Slack/API channels:
  # config.use_builtin_safety_guard :in_process_requests
  #
  # config.safety_guard :jobs do |&execute|
  #   Sidekiq::Testing.fake! { execute.call }
  # end
  #
  # Bypass ALL safety guards when specific methods are called (e.g. trusted admin actions):
  # config.bypass_guards_for_methods = [
  #   'ChangeApproval#approve_by!',
  #   'ChangeApproval#reject_by!'
  # ]

  # Per-channel settings (channel mode keys: 'slack', 'console'):
  # config.channels = {
  #   'slack' => {
  #     'allowed_usernames' => ['alice', 'bob'],                          # who can use the bot (or 'ALL')
  #     'allow_code_execution' => ['alice'],                              # who can run code directly via ``` (nil = everyone)
  #     'pinned_memory_tags' => ['sharding'],
  #     'bypass_guards_for_methods' => ['ChangeApproval#approve_by!']
  #   },
  #   'console' => { 'pinned_memory_tags' => [] }
  # }
end
