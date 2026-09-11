require 'spec_helper'
require 'rails_console_ai/line_editor'

RSpec.describe RailsConsoleAi::LineEditor do
  describe '.resolve' do
    it 'honours an explicit :readline preference' do
      expect(described_class.resolve(:readline)).to be_a(described_class::Readline_)
    end

    it 'falls back to Readline when Reline is unavailable' do
      allow(described_class).to receive(:reline_adapter).and_return(nil)
      expect(described_class.resolve(:reline)).to be_a(described_class::Readline_)
      expect(described_class.resolve(:auto)).to be_a(described_class::Readline_)
    end

    it 'prefers Reline when nothing is specified' do
      skip 'Reline not installed' unless described_class.reline_adapter
      expect(described_class.resolve(:auto)).to be_a(described_class::Reline_)
    end

    it 'points Reline at the given output so its menu is not captured' do
      skip 'Reline not installed' unless described_class.reline_adapter
      io = StringIO.new
      expect(Reline).to receive(:output=).with(io)
      described_class.resolve(:reline, output: io)
    end

    it 'does not try to redirect Readline, which writes below $stdout' do
      expect(described_class.resolve(:readline)).not_to respond_to(:output=)
    end
  end

  describe 'completion' do
    subject(:editor) { described_class.resolve(:readline) }

    before do
      editor.complete_with do
        [['/auto', 'command'], ['/find-shard', 'agent'], ['/restart-user-trial', 'skill']]
      end
    end

    it 'completes a slash prefix' do
      expect(editor.matches('/f')).to eq(['/find-shard'])
    end

    it 'offers nothing for ordinary prose, so typing is never interrupted' do
      expect(editor.matches('find')).to be_empty
      expect(editor.matches('what shard is user 1 on')).to be_empty
    end

    it 'returns nothing when no candidates have been supplied' do
      expect(described_class::Readline_.new.matches('/f')).to be_empty
    end
  end

  # Readline inserts only the common prefix of the candidates it is handed and
  # displays the rest for the eye, so a multi-match list can carry kind labels.
  # Reline inserts whichever row you arrow onto, verbatim, so it cannot.
  describe 'labelling an ambiguous Tab list' do
    let(:entries) do
      [['/retry', 'command'], ['/restart-user-trial', 'skill'], ['/resurrect-page', 'skill']]
    end

    subject(:editor) { described_class.resolve(:readline).complete_with { entries } }

    it 'says which matches are commands and which are skills or agents' do
      rows = editor.matches('/re')

      expect(rows.length).to eq(3)
      expect(rows[0]).to match(%r{\A/retry\s+command\z})
      expect(rows[1]).to match(%r{\A/restart-user-trial\s+skill\z})
    end

    it 'keeps the labels past the point where the slugs diverge' do
      # Everything Readline would insert is the common prefix; if a label could
      # reach into it, the label text would land in the buffer.
      rows = editor.matches('/re')
      expect(common_prefix(rows)).to eq('/re')
    end

    it 'pads so the labels line up' do
      rows = editor.matches('/re')
      expect(rows.map { |r| r.index(/command|skill|agent/) }.uniq.length).to eq(1)
    end

    it 'leaves a lone match bare, so it completes into the buffer cleanly' do
      expect(editor.matches('/ret')).to eq(['/retry'])
    end

    it 'never labels for Reline, whose menu inserts the row verbatim' do
      skip 'Reline not installed' unless described_class.reline_adapter
      reline = described_class::Reline_.new.complete_with { entries }
      expect(reline.matches('/re')).to eq(['/retry', '/restart-user-trial', '/resurrect-page'])
    end

    def common_prefix(list)
      shortest = list.min_by(&:length)
      shortest.length.downto(0) do |len|
        candidate = shortest[0, len]
        return candidate if list.all? { |c| c.start_with?(candidate) }
      end
      ''
    end
  end

  describe 'prompt escaping' do
    it 'wraps ANSI in \001..\002 for Readline width calculation' do
      prompt = described_class::Readline_.new.prompt('ai> ', "\e[33m")
      expect(prompt).to eq("\001\e[33m\002ai> \001\e[0m\002")
    end

    it 'leaves ANSI bare for Reline, which parses it itself' do
      skip 'Reline not installed' unless described_class.reline_adapter
      prompt = described_class::Reline_.new.prompt('ai> ', "\e[33m")
      expect(prompt).to eq("\e[33mai> \e[0m")
      expect(prompt).not_to include("\001")
    end
  end

  describe '#bind_auto_toggle' do
    it 'binds Shift-Tab through the inputrc parser on Readline' do
      expect(Readline).to receive(:parse_and_bind).with('"\e[Z": "\C-a\C-k/auto\C-m"')
      described_class.resolve(:readline).bind_auto_toggle
    end

    it 'is a no-op when Readline cannot bind keys' do
      allow(Readline).to receive(:respond_to?).with(:parse_and_bind).and_return(false)
      expect { described_class.resolve(:readline).bind_auto_toggle }.not_to raise_error
    end

    it 'binds Shift-Tab to the same macro bytes on Reline' do
      skip 'Reline not installed' unless described_class.reline_adapter
      expect(Reline.core.config).to receive(:add_default_key_binding)
        .with("\e[Z".bytes, "\C-a\C-k/auto\C-m".bytes)
      described_class::Reline_.new.bind_auto_toggle
    end
  end
end
