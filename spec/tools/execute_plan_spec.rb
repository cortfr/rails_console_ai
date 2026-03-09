require 'spec_helper'
require 'rails_console_ai/executor'
require 'rails_console_ai/tools/registry'

RSpec.describe 'execute_plan tool' do
  let(:test_binding) { binding }
  let(:executor) { RailsConsoleAi::Executor.new(test_binding) }
  let(:registry) { RailsConsoleAi::Tools::Registry.new(executor: executor) }

  let(:two_steps) do
    {
      'steps' => [
        { 'description' => 'Add two numbers', 'code' => '1 + 1' },
        { 'description' => 'Multiply two numbers', 'code' => '3 * 4' }
      ]
    }
  end

  describe 'registration' do
    it 'registers execute_plan when executor is provided' do
      names = registry.definitions.map { |d| d[:name] }
      expect(names).to include('execute_plan')
    end

    it 'does not register execute_plan when no executor is provided' do
      reg = RailsConsoleAi::Tools::Registry.new
      names = reg.definitions.map { |d| d[:name] }
      expect(names).not_to include('execute_plan')
    end
  end

  describe 'with auto_execute ON' do
    before do
      RailsConsoleAi.configuration.auto_execute = true
    end

    it 'executes all steps without prompting' do
      expect($stdin).not_to receive(:gets)

      result = registry.execute('execute_plan', two_steps)

      expect(result).to include('Step 1 (Add two numbers)')
      expect(result).to include('Return value: 2')
      expect(result).to include('Step 2 (Multiply two numbers)')
      expect(result).to include('Return value: 12')
    end

    it 'displays the plan overview' do
      output = capture_stdout { registry.execute('execute_plan', two_steps) }

      expect(output).to include('Plan (2 steps)')
      expect(output).to include('1. Add two numbers')
      expect(output).to include('2. Multiply two numbers')
    end

    it 'displays step progress during execution' do
      output = capture_stdout { registry.execute('execute_plan', two_steps) }

      expect(output).to include('Step 1/2: Add two numbers')
      expect(output).to include('Step 2/2: Multiply two numbers')
    end

    it 'captures printed output in step results' do
      steps = {
        'steps' => [
          { 'description' => 'Print hello', 'code' => 'puts "hello world"' }
        ]
      }

      result = registry.execute('execute_plan', steps)

      expect(result).to include('Output: hello world')
    end

    it 'returns empty string for no steps' do
      result = registry.execute('execute_plan', { 'steps' => [] })
      expect(result).to eq('No steps provided.')
    end

    it 'returns empty string for nil steps' do
      result = registry.execute('execute_plan', {})
      expect(result).to eq('No steps provided.')
    end

    it 'makes earlier step results available to later steps via shared binding' do
      steps = {
        'steps' => [
          { 'description' => 'Set a variable', 'code' => '@_plan_test_var = 42' },
          { 'description' => 'Use that variable', 'code' => '@_plan_test_var * 2' }
        ]
      }

      result = registry.execute('execute_plan', steps)

      expect(result).to include('Step 2 (Use that variable)')
      expect(result).to include('Return value: 84')
    end

    it 'stores each step result as step1, step2, etc.' do
      steps = {
        'steps' => [
          { 'description' => 'Return a number', 'code' => '42' },
          { 'description' => 'Double step1', 'code' => 'step1 * 2' }
        ]
      }

      result = registry.execute('execute_plan', steps)

      expect(result).to include('Step 1 (Return a number)')
      expect(result).to include('Return value: 42')
      expect(result).to include('Step 2 (Double step1)')
      expect(result).to include('Return value: 84')
    end

    it 'stores nil step results without error' do
      steps = {
        'steps' => [
          { 'description' => 'Print something', 'code' => 'puts "hello"' },
          { 'description' => 'Check step1 is nil', 'code' => 'step1.nil?' }
        ]
      }

      result = registry.execute('execute_plan', steps)

      expect(result).to include('Step 2 (Check step1 is nil)')
      expect(result).to include('Return value: true')
    end
  end

  describe 'with auto_execute OFF' do
    before do
      RailsConsoleAi.configuration.auto_execute = false
    end

    it 'prompts for plan approval and executes on y' do
      allow($stdin).to receive(:gets).and_return("y\n", "y\n", "y\n")

      result = registry.execute('execute_plan', two_steps)

      expect(result).to include('Step 1 (Add two numbers)')
      expect(result).to include('Return value: 2')
      expect(result).to include('Step 2 (Multiply two numbers)')
      expect(result).to include('Return value: 12')
    end

    it 'auto-accepts the single step when plan has only one step and user answers y' do
      one_step = {
        'steps' => [
          { 'description' => 'Add two numbers', 'code' => '1 + 1' }
        ]
      }

      # Only one stdin read: "y" for plan approval, no per-step prompt
      allow($stdin).to receive(:gets).and_return("y\n")

      result = registry.execute('execute_plan', one_step)

      expect(result).to include('Step 1 (Add two numbers)')
      expect(result).to include('Return value: 2')
    end

    it 'runs all steps without per-step prompts when user answers auto' do
      # Only one stdin read: "a" for plan approval, no per-step prompts
      allow($stdin).to receive(:gets).and_return("a\n")

      result = registry.execute('execute_plan', two_steps)

      expect(result).to include('Step 1 (Add two numbers)')
      expect(result).to include('Return value: 2')
      expect(result).to include('Step 2 (Multiply two numbers)')
      expect(result).to include('Return value: 12')
    end

    it 'does not change global auto_execute when using plan-level auto' do
      allow($stdin).to receive(:gets).and_return("auto\n")

      registry.execute('execute_plan', two_steps)

      expect(RailsConsoleAi.configuration.auto_execute).to eq(false)
    end

    it 'shows auto option in the accept prompt' do
      allow($stdin).to receive(:gets).and_return("a\n")

      output = capture_stdout { registry.execute('execute_plan', two_steps) }

      expect(output).to include('Accept plan? [y/N/a(uto)]')
    end

    it 'returns declined message with feedback when plan is rejected' do
      # Decline plan, then provide feedback
      allow($stdin).to receive(:gets).and_return("n\n", "use COUNT(Id) instead\n")

      result = registry.execute('execute_plan', two_steps)

      expect(result).to include('User declined the plan.')
      expect(result).to include('Feedback: use COUNT(Id) instead')
    end

    it 'immediately prompts for feedback on plan decline' do
      allow($stdin).to receive(:gets).and_return("n\n", "change step 2\n")

      output = capture_stdout { registry.execute('execute_plan', two_steps) }

      expect(output).to include('Plan declined.')
      expect(output).to include('What would you like changed?')
    end

    it 'handles empty feedback on plan decline' do
      allow($stdin).to receive(:gets).and_return("\n", "\n")

      result = registry.execute('execute_plan', two_steps)

      expect(result).to include('User declined the plan.')
      expect(result).to include('(no feedback provided)')
    end

    it 'stops mid-plan when user declines a step and asks for feedback' do
      # Accept plan, accept step 1, decline step 2, provide feedback
      allow($stdin).to receive(:gets).and_return("y\n", "y\n", "n\n", "skip this step\n")

      result = registry.execute('execute_plan', two_steps)

      expect(result).to include('Step 1 (Add two numbers)')
      expect(result).to include('Return value: 2')
      expect(result).to include('Step 2: User declined.')
      expect(result).to include('Feedback: skip this step')
      expect(result).not_to include('Return value: 12')
    end
  end

  describe 'plan display' do
    before do
      RailsConsoleAi.configuration.auto_execute = true
    end

    it 'shows full multi-line code in plan overview' do
      steps = {
        'steps' => [
          { 'description' => 'Multi-line step', 'code' => "x = 1\ny = 2\nx + y" }
        ]
      }

      output = capture_stdout { registry.execute('execute_plan', steps) }
      # Strip ANSI codes for matching (CodeRay adds syntax highlighting)
      plain = output.gsub(/\e\[[0-9;]*m/, '')

      expect(plain).to include('x = 1')
      expect(plain).to include('y = 2')
      expect(plain).to include('x + y')
    end
  end
end

def capture_stdout
  old_stdout = $stdout
  $stdout = StringIO.new
  yield
  $stdout.string
ensure
  $stdout = old_stdout
end
