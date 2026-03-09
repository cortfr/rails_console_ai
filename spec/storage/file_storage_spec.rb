require 'spec_helper'
require 'rails_console_ai/storage/file_storage'
require 'tmpdir'

RSpec.describe RailsConsoleAi::Storage::FileStorage do
  let(:tmpdir) { Dir.mktmpdir('rails_console_ai_test') }
  subject(:storage) { described_class.new(tmpdir) }

  after { FileUtils.rm_rf(tmpdir) }

  describe '#read' do
    it 'returns nil for non-existent key' do
      expect(storage.read('missing.yml')).to be_nil
    end

    it 'reads an existing file' do
      File.write(File.join(tmpdir, 'test.yml'), 'hello')
      expect(storage.read('test.yml')).to eq('hello')
    end
  end

  describe '#write' do
    it 'creates the file and parent directories' do
      storage.write('sub/dir/test.yml', 'content')
      expect(File.read(File.join(tmpdir, 'sub/dir/test.yml'))).to eq('content')
    end

    it 'overwrites existing files' do
      storage.write('test.yml', 'first')
      storage.write('test.yml', 'second')
      expect(storage.read('test.yml')).to eq('second')
    end

    it 'raises StorageError on permission failure' do
      FileUtils.mkdir_p(File.join(tmpdir, 'readonly'))
      File.chmod(0o000, File.join(tmpdir, 'readonly'))

      expect {
        storage.write('readonly/test.yml', 'content')
      }.to raise_error(RailsConsoleAi::Storage::StorageError, /Cannot write/)
    ensure
      File.chmod(0o755, File.join(tmpdir, 'readonly'))
    end
  end

  describe '#list' do
    it 'returns empty array when no files match' do
      expect(storage.list('*.yml')).to eq([])
    end

    it 'lists files matching a pattern' do
      storage.write('memories.yml', 'data')
      storage.write('skills/a.md', 'skill a')
      storage.write('skills/b.md', 'skill b')

      expect(storage.list('skills/*.md')).to eq(['skills/a.md', 'skills/b.md'])
    end
  end

  describe '#delete' do
    it 'deletes an existing file' do
      storage.write('test.yml', 'data')
      expect(storage.delete('test.yml')).to be true
      expect(storage.exists?('test.yml')).to be false
    end

    it 'returns false for non-existent file' do
      expect(storage.delete('missing.yml')).to be false
    end
  end

  describe '#exists?' do
    it 'returns false for missing key' do
      expect(storage.exists?('nope.yml')).to be false
    end

    it 'returns true for existing key' do
      storage.write('test.yml', 'data')
      expect(storage.exists?('test.yml')).to be true
    end
  end

  describe 'path traversal protection' do
    it 'cannot escape the root directory' do
      # Write a file outside the storage root
      outside_file = File.join(File.dirname(tmpdir), 'secret.yml')
      File.write(outside_file, 'secret data')

      # Attempting traversal should not find it
      content = storage.read('../secret.yml')
      expect(content).to be_nil
    ensure
      File.delete(outside_file) if File.exist?(outside_file)
    end
  end
end
