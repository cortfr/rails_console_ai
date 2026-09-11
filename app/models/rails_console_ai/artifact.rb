require 'securerandom'
require 'rails_console_ai/slash_commands'

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
    validates :slug, presence: true, uniqueness: { case_sensitive: false }
    validates :content, presence: true
    validates :content_type, inclusion: {
      in: CONTENT_TYPES.keys,
      message: "must be one of: #{CONTENT_TYPES.keys.join(', ')}"
    }
    validate :content_within_limit

    before_validation :assign_token
    before_validation :assign_slug
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

    # How the assistant addresses an artifact across turns and sessions: the
    # slug it was given, the name a human typed, or the token from a URL. Name
    # is matched case-insensitively because the user will not retype it exactly.
    def self.find_by_handle(handle)
      handle = handle.to_s.strip
      return nil if handle.empty?

      slug = RailsConsoleAi::SlashCommands.slugify(handle)
      find_by(slug: slug) ||
        find_by(slug: handle) ||
        where('LOWER(name) = ?', handle.downcase).first ||
        find_by(token: handle) ||
        most_recent_matching(handle)
    end

    # The handle a new artifact with this name would take, minus any suffix the
    # uniqueness check would add.
    def self.slug_for(name)
      RailsConsoleAi::SlashCommands.slugify(name)
    end

    # Leading "20260911_" / "20260911-", as added to new names.
    DATE_PREFIX = /\A\d{8}[_-]/.freeze

    def self.date_prefix_for(time = Time.now)
      "#{time.strftime('%Y%m%d')}_"
    end

    # The slug mirrors the name, date and all, so the two always correspond:
    # "20260911_Dog on a bike" is addressed as 20260911-dog-on-a-bike.
    def self.base_slug_for(name)
      slug_for(name).sub(DATE_PREFIX, '')
    end

    def base_slug
      slug.to_s.sub(DATE_PREFIX, '')
    end

    # Resolves an undated handle to the most recent artifact carrying it, so a
    # user can say "the churn report" without knowing which day's it was.
    # Only a convenience for reading and deleting — saving matches exactly.
    def self.most_recent_matching(handle)
      base = base_slug_for(handle)
      return nil if base.empty?

      candidates = where('slug = ? OR slug LIKE ?', base, "________-#{base}")
                   .order(created_at: :desc).to_a
      candidates.find { |a| a.base_slug == base }
    end

    # Applies the date stamp unless the caller already supplied one, or the app
    # has turned stamping off.
    def self.stamped_name(name, time = Time.now)
      name = name.to_s.strip
      # A blank name must stay blank: stamping it would smuggle an unnamed
      # artifact past the presence validation as "20260911_".
      return name if name.empty?
      return name unless RailsConsoleAi.configuration.artifact_date_prefix
      return name if name =~ DATE_PREFIX
      "#{date_prefix_for(time)}#{name}"
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

    def assign_slug
      return unless slug.to_s.empty?

      base = self.class.slug_for(name)
      # A name with nothing sluggable in it leaves just the date stamp, which
      # would collide with the next such name saved the same day.
      # The separator is already gone when nothing followed it, so match the
      # date with the separator optional.
      if base.sub(/\A\d{8}[_-]?/, '').empty?
        stamp = base[/\A\d{8}/]
        base = [stamp, "artifact-#{SecureRandom.hex(4)}"].compact.join('-')
      end

      candidate = base
      n = 1
      # Only reached when the caller did not mean to update an existing artifact
      # (save_artifact looks the slug up first), so the newcomer takes a suffix.
      while self.class.where(slug: candidate).where.not(id: id).exists?
        n += 1
        candidate = "#{base}-#{n}"
      end
      self.slug = candidate
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
