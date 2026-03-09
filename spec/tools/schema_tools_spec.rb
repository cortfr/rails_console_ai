require 'spec_helper'
require 'rails_console_ai/tools/schema_tools'

RSpec.describe RailsConsoleAi::Tools::SchemaTools do
  subject(:tools) { described_class.new }

  describe '#list_tables' do
    context 'when ActiveRecord is not connected' do
      before do
        stub_const('ActiveRecord::Base', double(connected?: false))
      end

      it 'returns not connected message' do
        expect(tools.list_tables).to include('not connected')
      end
    end
  end

  describe '#describe_table' do
    it 'returns not connected when ActiveRecord is unavailable' do
      expect(tools.describe_table(nil)).to include('not connected')
      expect(tools.describe_table('')).to include('not connected')
    end

    context 'when ActiveRecord is connected' do
      let(:mock_connection) { double(tables: ['users'], columns: [], indexes: []) }

      before do
        stub_const('ActiveRecord::Base', double(connected?: true, connection: mock_connection))
      end

      it 'returns error for nil table name' do
        expect(tools.describe_table(nil)).to include('required')
      end

      it 'returns error for empty table name' do
        expect(tools.describe_table('')).to include('required')
      end

      it 'returns not found for unknown table' do
        expect(tools.describe_table('nonexistent')).to include('not found')
      end
    end
  end
end
