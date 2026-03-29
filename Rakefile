require 'rspec/core/rake_task'

RSpec::Core::RakeTask.new(:spec)

RSpec::Core::RakeTask.new(:integration) do |t|
  t.pattern = 'spec/integration/**/*_spec.rb'
  t.rspec_opts = '--format documentation --exclude-pattern ""'
end

task :default => :spec
