require 'rails_console_ai/tools/memory_tools'

module RailsConsoleAi
  class MemoriesController < RailsConsoleAi::ApplicationController
    before_action :load_memory, only: [:show, :edit, :update, :destroy, :approve]

    def index
      @memories = Tools::MemoryTools.new.load_all_memories
      @q = params[:q].to_s.strip
      unless @q.empty?
        needle = @q.downcase
        @memories = @memories.select { |m|
          [m['name'], m['description'], Array(m['tags']).join(' ')].compact.join(' ').downcase.include?(needle)
        }
      end

      @sort = params[:sort].to_s
      if @sort == 'used'
        @memories = @memories.sort_by { |m| [-(m['use_count'].to_i), m['name'].to_s.downcase] }
      end
    end

    def show
      @versions = @memory.versions if @memory.is_a?(RailsConsoleAi::Memory)
    end

    def new
      @memory = Memory.new(content: new_memory_template)
    end

    def create
      @memory = Memory.new
      attrs = memory_params
      begin
        @memory.update_with_version!(
          attrs,
          edited_by: edited_by_param,
          change_note: params[:change_note].presence
        )
        redirect_to memory_path(@memory), notice: 'Memory created.'
      rescue ActiveRecord::RecordInvalid => e
        flash.now[:alert] = e.message
        render :new
      end
    end

    def edit
      redirect_to memories_path, alert: file_memory_message and return unless @memory.is_a?(RailsConsoleAi::Memory)
    end

    def update
      redirect_to memories_path, alert: file_memory_message and return unless @memory.is_a?(RailsConsoleAi::Memory)

      begin
        @memory.update_with_version!(
          memory_params,
          edited_by: edited_by_param,
          change_note: params[:change_note].presence
        )
        redirect_to memory_path(@memory), notice: 'Memory updated.'
      rescue ActiveRecord::RecordInvalid => e
        flash.now[:alert] = e.message
        render :edit
      end
    end

    def destroy
      if @memory.is_a?(RailsConsoleAi::Memory)
        @memory.destroy
        redirect_to memories_path, notice: 'Memory deleted. Past versions remain in history.'
      else
        redirect_to memories_path, alert: file_memory_message
      end
    end

    def approve
      redirect_to memories_path, alert: file_memory_message and return unless @memory.is_a?(RailsConsoleAi::Memory)

      approver = params[:approved_by].presence ||
                 (request.respond_to?(:remote_user) && request.remote_user.presence) ||
                 'web'

      if @memory.approved?
        redirect_to memory_path(@memory), notice: 'Memory is already approved.'
        return
      end

      begin
        @memory.approve!(approved_by: approver)
        redirect_to memory_path(@memory), notice: "Approved by #{approver}. The AI can now recall this memory."
      rescue ArgumentError, ActiveRecord::RecordInvalid => e
        redirect_to memory_path(@memory), alert: "Could not approve: #{e.message}"
      end
    end

    def diff
      @memory = Memory.find(params[:memory_id])
      @from = @memory.versions.find(params[:from])
      @to   = params[:to].present? ? @memory.versions.find(params[:to]) : nil
      @to_label   = @to ? "Version ##{@to.id}" : 'Current'
      @to_content = @to ? @to.content : @memory.content
    end

    private

    def load_memory
      if params[:id].to_s =~ /\A\d+\z/
        @memory = Memory.find(params[:id])
        return
      end

      # Non-numeric :id — prefer the AR record if a DB row matches by name or slug,
      # so write actions (update/destroy) get the AR object, not a read-only Hash.
      ar = Memory.where('LOWER(name) = ?', params[:id].to_s.downcase).first
      ar ||= Memory.all.find { |m| slugify(m.name) == params[:id] }
      if ar
        @memory = ar
        return
      end

      all = Tools::MemoryTools.new.load_all_memories
      @memory = all.find { |m| slugify(m['name']) == params[:id] || m['name'] == params[:id] }
      raise ActiveRecord::RecordNotFound, "Memory not found: #{params[:id]}" unless @memory
    end

    def memory_params
      { content: params.require(:memory)[:content].to_s }
    end

    def edited_by_param
      params[:edited_by].presence || 'web'
    end

    def new_memory_template
      <<~MD
        ---
        name:
        tags: []
        ---

        The fact or pattern you're persisting.
      MD
    end

    def slugify(name)
      name.to_s.downcase.strip
        .gsub(/[^a-z0-9\s-]/, '')
        .gsub(/[\s]+/, '-')
        .gsub(/-+/, '-')
    end

    def file_memory_message
      'This memory lives on disk under .rails_console_ai/memories/. Edit the file directly to change it.'
    end
  end
end
