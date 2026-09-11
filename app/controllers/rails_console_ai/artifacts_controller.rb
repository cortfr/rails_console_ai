module RailsConsoleAi
  class ArtifactsController < RailsConsoleAi::ApplicationController
    before_action :load_artifact, only: [:show, :raw, :download, :destroy]

    # Artifact content is written by the model, from data the model read — some
    # of which other people wrote. Treat it as untrusted and never let it execute
    # on this origin.
    #
    # `sandbox` with no tokens is the strictest form: unique opaque origin, no
    # scripts, no forms, no popups. It is set as a *header* rather than relying on
    # the iframe's sandbox attribute alone, because the raw URL can be opened
    # directly in a tab, where no iframe attribute applies. nosniff stops a
    # text/plain artifact being re-interpreted as something executable.
    ARTIFACT_CSP = "sandbox; default-src 'none'; style-src 'unsafe-inline'; img-src data:; font-src data:".freeze

    def index
      @artifacts = Artifact.newest_first
      @q = params[:q].to_s.strip
      unless @q.empty?
        needle = "%#{@q.downcase}%"
        @artifacts = @artifacts.where(
          'LOWER(name) LIKE :q OR LOWER(COALESCE(description, \'\')) LIKE :q', q: needle
        )
      end
      @artifacts = @artifacts.limit(200).to_a
    end

    def show
    end

    # The bytes themselves, sandboxed. The show page frames this URL.
    def raw
      send_artifact(disposition: 'inline')
    end

    def download
      send_artifact(disposition: 'attachment')
    end

    def destroy
      @artifact.destroy
      redirect_to artifacts_path, notice: "Artifact \"#{@artifact.name}\" deleted."
    end

    private

    def send_artifact(disposition:)
      response.headers['Content-Security-Policy'] = ARTIFACT_CSP
      response.headers['X-Content-Type-Options'] = 'nosniff'
      # Belt and braces for older browsers that honour it.
      response.headers['X-Frame-Options'] = 'SAMEORIGIN'

      send_data @artifact.content,
                type: "#{@artifact.content_type}; charset=utf-8",
                disposition: disposition,
                filename: @artifact.filename
    end

    # Addressed by slug, so the URL says what it points at. Tokens still resolve:
    # links handed out before slugs existed, or shared from an older version,
    # must keep working.
    def load_artifact
      @artifact = Artifact.find_by_handle(params[:id])
      redirect_to artifacts_path, alert: 'Artifact not found.' unless @artifact
    end
  end
end
