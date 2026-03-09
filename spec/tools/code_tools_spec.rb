require 'spec_helper'
require 'fileutils'
require 'tmpdir'
require 'rails_console_ai/tools/code_tools'

RSpec.describe RailsConsoleAi::Tools::CodeTools do
  subject(:tools) { described_class.new }

  describe '#read_file' do
    it 'returns error for nil path' do
      expect(tools.read_file(nil)).to include('required')
    end

    it 'returns error for empty path' do
      expect(tools.read_file('')).to include('required')
    end

    it 'returns not available when Rails.root is nil' do
      # No Rails defined in test env
      expect(tools.read_file('app/models/user.rb')).to include('not available')
    end

    context 'with Rails.root available' do
      let(:tmpdir) { Dir.mktmpdir }
      let(:test_file) { File.join(tmpdir, 'app', 'models', 'test.rb') }

      before do
        FileUtils.mkdir_p(File.dirname(test_file))
        # Create a file with 20 lines
        File.write(test_file, (1..20).map { |i| "line #{i}\n" }.join)
        stub_const('Rails', double(root: Pathname.new(tmpdir)))
        allow(Rails).to receive(:respond_to?).with(:root).and_return(true)
      end

      after { FileUtils.rm_rf(tmpdir) }

      it 'reads entire small file' do
        result = tools.read_file('app/models/test.rb')
        expect(result).to include('1: line 1')
        expect(result).to include('20: line 20')
      end

      it 'reads a specific line range with start_line and end_line' do
        result = tools.read_file('app/models/test.rb', start_line: 5, end_line: 10)
        expect(result).to include('Lines 5-10 of 20')
        expect(result).to include('5: line 5')
        expect(result).to include('10: line 10')
        expect(result).not_to include('4: line 4')
        expect(result).not_to include('11: line 11')
      end

      it 'reads from start_line to end of file when end_line is omitted' do
        result = tools.read_file('app/models/test.rb', start_line: 18)
        expect(result).to include('Lines 18-20 of 20')
        expect(result).to include('18: line 18')
        expect(result).to include('20: line 20')
        expect(result).not_to include('17: line 17')
      end

      it 'reads from beginning to end_line when start_line is omitted' do
        result = tools.read_file('app/models/test.rb', end_line: 3)
        expect(result).to include('Lines 1-3 of 20')
        expect(result).to include('1: line 1')
        expect(result).to include('3: line 3')
        expect(result).not_to include('4: line 4')
      end

      it 'returns error when start_line is beyond end of file' do
        result = tools.read_file('app/models/test.rb', start_line: 25)
        expect(result).to include('beyond end of file')
      end

      it 'truncates large files and suggests start_line/end_line' do
        # Create a file larger than MAX_FILE_LINES
        large_file = File.join(tmpdir, 'app', 'models', 'large.rb')
        File.write(large_file, (1..600).map { |i| "line #{i}\n" }.join)
        result = tools.read_file('app/models/large.rb')
        expect(result).to include('truncated')
        expect(result).to include('start_line/end_line')
        expect(result).to include('600 total lines')
      end
    end
  end

  describe '#search_code' do
    it 'returns error for nil query' do
      expect(tools.search_code(nil)).to include('required')
    end

    it 'returns error for empty query' do
      expect(tools.search_code('')).to include('required')
    end
  end

  describe '#list_files' do
    it 'returns not available when Rails.root is nil' do
      expect(tools.list_files('app')).to include('not available')
    end
  end
end
