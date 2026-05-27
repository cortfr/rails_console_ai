module RailsConsoleAi
  class MemoryVersionsController < ApplicationController
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
        {
          name:        version.name,
          description: version.description,
          tags:        Array(version.tags)
        },
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
