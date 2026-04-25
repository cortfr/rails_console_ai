#!/usr/bin/env ruby
# Smoke test a Claude model against the Anthropic or Bedrock provider before
# adopting it. Runs four checks by default: plain text, single tool call,
# parallel tool calls, and prompt caching. Exits non-zero on any failure.
#
# Usage:
#   ANTHROPIC_API_KEY=... bin/smoke_model.rb --model claude-opus-4-7
#   AWS_PROFILE=...       bin/smoke_model.rb --model us.anthropic.claude-opus-4-7-v1
#   bin/smoke_model.rb --model claude-sonnet-4-6 --checks plain,tool
#   bin/smoke_model.rb --provider anthropic --model claude-opus-4-7
#
# Provider is inferred when omitted: claude-* → anthropic, us.anthropic.* → bedrock.

require 'optparse'

$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))
require 'rails_console_ai'
require 'rails_console_ai/providers/base'
require 'rails_console_ai/providers/anthropic'
require 'rails_console_ai/providers/bedrock'

# ---------------------------------------------------------------------------
# Tool shim — same surface as Tools::Registry, no executor required.
# ---------------------------------------------------------------------------

class WeatherTool
  HANDLERS = {
    'get_weather' => ->(args) { "It is 18C and sunny in #{args['city']}." }
  }.freeze

  DEFINITIONS = [
    {
      name: 'get_weather',
      description: 'Get the current weather for a city.',
      parameters: {
        'type' => 'object',
        'properties' => { 'city' => { 'type' => 'string', 'description' => 'City name' } },
        'required' => ['city']
      }
    }
  ].freeze

  def to_anthropic_format
    DEFINITIONS.map { |d| { 'name' => d[:name], 'description' => d[:description], 'input_schema' => d[:parameters] } }
  end

  def to_bedrock_format
    DEFINITIONS.map { |d| { tool_spec: { name: d[:name], description: d[:description], input_schema: { json: d[:parameters] } } } }
  end

  def execute(name, args)
    HANDLERS.fetch(name) { ->(_) { "unknown tool: #{name}" } }.call(args || {})
  end
end

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------

def infer_provider(model)
  case model
  when /\A(us|eu|apac)\.anthropic\./, /\Aanthropic\./ then 'bedrock'
  when /\Aclaude-/                                    then 'anthropic'
  end
end

def configure(provider, model, region)
  RailsConsoleAi.configure do |c|
    c.provider = provider.to_sym
    c.model    = model
    if provider == 'anthropic'
      c.api_key = ENV['ANTHROPIC_API_KEY']
    else
      c.bedrock_region = region
    end
    c.max_tokens = 512
    c.debug      = ENV['DEBUG'] == '1'
  end
  cfg = RailsConsoleAi.configuration
  cfg.validate!
  cfg
end

def build_provider(provider, cfg)
  klass = provider == 'anthropic' ? RailsConsoleAi::Providers::Anthropic : RailsConsoleAi::Providers::Bedrock
  klass.new(cfg)
end

# ---------------------------------------------------------------------------
# Checks — each returns a hash with :ok and free-form detail keys
# ---------------------------------------------------------------------------

def check_plain(provider)
  result = provider.chat(
    [{ role: 'user', content: 'Reply with exactly: SMOKE_OK' }],
    system_prompt: 'You are a smoke test. Output only what is requested.'
  )
  { ok: result.text.to_s.include?('SMOKE_OK'), text: result.text, in: result.input_tokens, out: result.output_tokens }
end

def check_tool(provider)
  tools = WeatherTool.new
  messages = [{ role: 'user', content: "What's the weather in Paris? Use the tool, then state the result in one sentence." }]
  rounds = 0
  total_in = total_out = 0
  final = nil

  loop do
    rounds += 1
    r = provider.chat_with_tools(messages, tools: tools, system_prompt: 'You have a weather tool.')
    total_in  += r.input_tokens.to_i
    total_out += r.output_tokens.to_i

    if r.stop_reason == :tool_use && r.tool_calls.any?
      messages << provider.format_assistant_message(r)
      r.tool_calls.each do |tc|
        messages << provider.format_tool_result(tc[:id], tools.execute(tc[:name], tc[:arguments]))
      end
    else
      final = r.text
      break
    end
    break if rounds >= 4
  end

  ok = final.to_s.include?('Paris') && final.to_s.match?(/sunny|18/i)
  { ok: ok, text: final, rounds: rounds, in: total_in, out: total_out }
end

def check_parallel(provider)
  tools = WeatherTool.new
  msgs = [{ role: 'user', content: 'Get the weather in Paris and in London. Call the tool once for each city in the same response.' }]
  r = provider.chat_with_tools(
    msgs,
    tools: tools,
    system_prompt: 'You have a weather tool. When asked about multiple cities, issue all tool calls in parallel within a single response.'
  )
  cities = r.tool_calls.map { |tc| (tc[:arguments] || {})['city'] }.compact
  ok = r.tool_calls.length >= 2 &&
       cities.any? { |c| c.match?(/Paris/i) } &&
       cities.any? { |c| c.match?(/London/i) }
  { ok: ok, calls: r.tool_calls.length, cities: cities, in: r.input_tokens, out: r.output_tokens }
end

def check_cache(provider)
  # Anthropic requires >=1024 tokens of cacheable prefix for sonnet/opus.
  # Pad the system prompt with deterministic filler so the same prefix is sent twice.
  filler = (("This is filler context line for the prompt cache test. " * 8) + "\n") * 80
  system = "You are a smoke test for prompt caching.\n#{filler}\nWhen asked, respond with exactly: CACHE_OK"
  msgs = [{ role: 'user', content: 'Respond with the codeword.' }]

  first  = provider.chat(msgs, system_prompt: system)
  cw1 = first.cache_write_input_tokens.to_i
  cr1 = first.cache_read_input_tokens.to_i

  # Cache writes need a moment to become readable; retry on miss.
  cw2 = cr2 = in2 = 0
  attempts = 0
  loop do
    attempts += 1
    sleep(0.75 * attempts)
    second = provider.chat(msgs, system_prompt: system)
    cw2 = second.cache_write_input_tokens.to_i
    cr2 = second.cache_read_input_tokens.to_i
    in2 = second.input_tokens.to_i
    break if cr2 > 0 || attempts >= 3
  end

  # PASS if cache was either read on call 2, or already warm on call 1 (cr1>0).
  ok = cr2 > 0 || cr1 > 0
  { ok: ok, write1: cw1, read1: cr1, write2: cw2, read2: cr2, in1: first.input_tokens, in2: in2, attempts: attempts }
end

# ---------------------------------------------------------------------------
# Runner
# ---------------------------------------------------------------------------

CHECKS = {
  'plain'    => method(:check_plain),
  'tool'     => method(:check_tool),
  'parallel' => method(:check_parallel),
  'cache'    => method(:check_cache),
}.freeze

def run_check(name, provider)
  fn = CHECKS.fetch(name)
  t0 = Time.now
  data = fn.call(provider)
  dt = ((Time.now - t0) * 1000).round
  status = data[:ok] ? "\e[32mPASS\e[0m" : "\e[31mFAIL\e[0m"
  detail = data.reject { |k, _| k == :ok }.map { |k, v| "#{k}=#{v.inspect}" }.join(' ')
  puts "  [#{name.ljust(8)}] #{status} #{dt}ms #{detail}"
  data[:ok]
rescue => e
  puts "  [#{name.ljust(8)}] \e[31mERROR\e[0m #{e.class}: #{e.message}"
  warn e.backtrace.first(5).join("\n") if ENV['DEBUG'] == '1'
  false
end

opts = { checks: CHECKS.keys.join(','), region: 'us-east-1' }
OptionParser.new do |o|
  o.banner = "Usage: #{$0} --model MODEL [--provider PROVIDER] [--checks LIST] [--region REGION]"
  o.on('--model MODEL', 'model ID (e.g. claude-opus-4-7)') { |v| opts[:model] = v }
  o.on('--provider PROV', 'anthropic|bedrock (inferred from model if omitted)') { |v| opts[:provider] = v }
  o.on('--checks LIST', "comma-separated subset of: #{CHECKS.keys.join(',')}") { |v| opts[:checks] = v }
  o.on('--region REGION', 'bedrock region (default: us-east-1)') { |v| opts[:region] = v }
end.parse!(ARGV)

abort 'Missing --model. Run with --help for usage.' unless opts[:model]
provider_name = opts[:provider] || infer_provider(opts[:model])
abort "Could not infer provider from model #{opts[:model].inspect}; pass --provider anthropic|bedrock" unless provider_name
abort "Unknown provider: #{provider_name}" unless %w[anthropic bedrock].include?(provider_name)

requested = opts[:checks].split(',').map(&:strip)
unknown = requested - CHECKS.keys
abort "Unknown checks: #{unknown.join(',')}. Valid: #{CHECKS.keys.join(',')}" if unknown.any?

cfg = configure(provider_name, opts[:model], opts[:region])
provider = build_provider(provider_name, cfg)

puts "smoke test: provider=#{provider_name} model=#{opts[:model]} checks=#{requested.join(',')}"
results = requested.map { |name| [name, run_check(name, provider)] }

passed = results.count { |_, ok| ok }
failed = results.reject { |_, ok| ok }.map(&:first)
puts
if failed.empty?
  puts "\e[32mALL PASS\e[0m (#{passed}/#{results.length})"
else
  puts "\e[31mFAILED\e[0m: #{failed.join(', ')} (#{passed}/#{results.length} passed)"
  exit 1
end
