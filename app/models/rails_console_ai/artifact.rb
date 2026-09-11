require 'securerandom'

module RailsConsoleAi
  # A file the assistant produced — an HTML report, a CSV extract, a JSON dump —
  # kept so it can be looked at in the admin UI instead of scrolling past in the
  # console. Unlike skills and agents these are outputs, not configuration, so
  # there is no propose/approve cycle and no file-backed source.
  class Artifact < ActiveRecord::Base
    self.table_name = 'rails_console_ai_artifacts'

    # Content types the UI knows how to serve. Anything outside this list is
    # rejected rather than passed through: the value reaches a Content-Type
    # header, and letting the model choose it freely is how you end up serving
    # something the browser treats as a script on your own origin.
    CONTENT_TYPES = {
      'text/html'        => { ext: 'html', renders: true },
      'text/markdown'    => { ext: 'md',   renders: false },
      'text/csv'         => { ext: 'csv',  renders: false },
      'application/json' => { ext: 'json', renders: false },
      'text/plain'       => { ext: 'txt',  renders: false }
    }.freeze

    # A generated report is a few hundred KB at the very outside. The cap is here
    # because the content lands in a text column and in a single console turn's
    # memory, and a runaway generation shouldn't be able to fill either.
    MAX_BYTES = 2_000_000

    belongs_to :session,
               class_name: 'RailsConsoleAi::Session',
               foreign_key: :session_id,
               optional: true

    validates :name, presence: true, length: { maximum: 255 }
    validates :content, presence: true
    validates :content_type, inclusion: {
      in: CONTENT_TYPES.keys,
      message: "must be one of: #{CONTENT_TYPES.keys.join(', ')}"
    }
    validate :content_within_limit

    before_validation :assign_token
    before_validation :measure_content

    scope :newest_first, -> { order(created_at: :desc) }

    def self.connection
      klass = RailsConsoleAi.configuration.connection_class
      if klass
        klass = Object.const_get(klass) if klass.is_a?(String)
        klass.connection
      else
        super
      end
    end

    # False when the gem's tables haven't been installed, so callers can say
    # "run ai_db_setup" instead of surfacing a raw ActiveRecord error.
    def self.available?
      connection.table_exists?(table_name)
    rescue ::ActiveRecord::ActiveRecordError, ::ActiveRecord::NoDatabaseError
      false
    end

    def self.find_by_token!(token)
      find_by!(token: token.to_s)
    end

    def extension
      CONTENT_TYPES.dig(content_type, :ext) || 'txt'
    end

    # Whether the show page offers a rendered preview. Only HTML gets one, and
    # even then it is rendered inside a sandboxed frame — see ArtifactsController.
    def renderable?
      !!CONTENT_TYPES.dig(content_type, :renders)
    end

    def filename
      base = name.to_s.strip.downcase
        .gsub(/[^a-z0-9]+/, '-')
        .gsub(/-+/, '-')
        .sub(/\A-/, '').sub(/-\z/, '')
      base = "artifact-#{id}" if base.empty?
      "#{base}.#{extension}"
    end

    def human_size
      bytes = byte_size.to_i
      return "#{bytes} B" if bytes < 1024
      return "#{(bytes / 1024.0).round(1)} KB" if bytes < 1024 * 1024
      "#{(bytes / 1024.0 / 1024.0).round(1)} MB"
    end

    private

    def assign_token
      self.token = SecureRandom.hex(16) if token.to_s.empty?
    end

    def measure_content
      self.byte_size = content.to_s.bytesize
    end

    def content_within_limit
      return if content.to_s.bytesize <= MAX_BYTES
      errors.add(:content, "is #{content.to_s.bytesize} bytes, over the #{MAX_BYTES} byte limit")
    end
  end
end
