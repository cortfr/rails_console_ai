module RailsConsoleAi
  class MemoryVersionsController < RailsConsoleAi::ApplicationController
    before_action :load_memory

    def index
      @versions = @memory.versions
    end

    def show
      @version = @memory.versions.find(params[:id])
    end

    def restore
      version = @memory.versions.find(params[:id])
      @memory.update_with_version!(
        { content: version.content },
        edited_by: params[:edited_by].presence || 'web',
        change_note: "Restored from version ##{version.id}"
      )
      redirect_to memory_path(@memory), notice: "Restored version ##{version.id}."
    end

    private

    def load_memory
      @memory = Memory.find(params[:memory_id])
    end
  end
end
