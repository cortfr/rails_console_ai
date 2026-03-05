require_relative 'lib/console_agent/version'

Gem::Specification.new do |s|
  s.name        = 'console_agent'
  s.version     = ConsoleAgent::VERSION
  s.summary     = 'AI-powered Rails console assistant'
  s.description = 'An LLM-powered agent for your Rails console. Ask questions in natural language, get executable Ruby code.'
  s.authors     = ['Cortfr']
  s.email       = 'cortfr@gmail.com'
  s.homepage    = 'https://github.com/cortfr/console_agent'
  s.license     = 'MIT'

  s.files         = Dir['lib/**/*', 'app/**/*', 'config/**/*', 'LICENSE', 'README.md', 'CHANGELOG.md']
  s.require_paths = ['lib']

  s.required_ruby_version = '>= 2.5'

  s.add_dependency 'rails',  '>= 5.0'
  s.add_dependency 'faraday', '>= 1.0'

  s.add_development_dependency 'rspec',    '~> 3.0'
  s.add_development_dependency 'webmock',  '~> 3.0'
  s.add_development_dependency 'rake',     '>= 12.0'
end
