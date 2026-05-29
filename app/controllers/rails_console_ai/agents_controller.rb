require 'rails_console_ai/agent_loader'

module RailsConsoleAi
  class AgentsController < ApplicationController
    before_action :load_agent, only: [:show, :edit, :update, :destroy, :approve]

    def index
      @agents = AgentLoader.new.load_all_agents
      @q = params[:q].to_s.strip
      unless @q.empty?
        needle = @q.downcase
        @agents = @agents.select { |a|
          [a['name'], a['description'], Array(a['tools']).join(' ')].compact.join(' ').downcase.include?(needle)
        }
      end

      @sort = params[:sort].to_s
      if @sort == 'used'
        @agents = @agents.sort_by { |a| [-(a['use_count'].to_i), a['name'].to_s.downcase] }
      end
    end

    def show
      @versions = @agent.versions if @agent.is_a?(RailsConsoleAi::Agent)
    end

    def new
      # Allow prefilling from a built-in (the "Create override" action on the show page).
      @agent = Agent.new
      if params[:from_builtin].present?
        builtin = AgentLoader.new.load_all_agents.find { |a|
          a['source'] == :builtin && a['name'].to_s.downcase == params[:from_builtin].to_s.downcase
        }
        if builtin
          @agent.content = AgentLoader.dump(
            name: builtin['name'],
            description: builtin['description'],
            body: builtin['body'],
            max_rounds: builtin['max_rounds'],
            model: builtin['model'],
            tools: Array(builtin['tools'])
          )
        end
      end
      @agent.content ||= new_agent_template
    end

    def create
      @agent = Agent.new
      begin
        @agent.update_with_version!(
          agent_params,
          edited_by: edited_by_param,
          change_note: params[:change_note].presence
        )
        redirect_to agent_path(@agent), notice: 'Agent created.'
      rescue ActiveRecord::RecordInvalid => e
        flash.now[:alert] = e.message
        render :new
      end
    end

    def edit
      redirect_to agents_path, alert: read_only_message and return unless @agent.is_a?(RailsConsoleAi::Agent)
    end

    def update
      redirect_to agents_path, alert: read_only_message and return unless @agent.is_a?(RailsConsoleAi::Agent)

      begin
        @agent.update_with_version!(
          agent_params,
          edited_by: edited_by_param,
          change_note: params[:change_note].presence
        )
        redirect_to agent_path(@agent), notice: 'Agent updated.'
      rescue ActiveRecord::RecordInvalid => e
        flash.now[:alert] = e.message
        render :edit
      end
    end

    def destroy
      if @agent.is_a?(RailsConsoleAi::Agent)
        @agent.destroy
        redirect_to agents_path, notice: 'Agent deleted. Past versions remain in history.'
      else
        redirect_to agents_path, alert: read_only_message
      end
    end

    def approve
      redirect_to agents_path, alert: read_only_message and return unless @agent.is_a?(RailsConsoleAi::Agent)

      approver = params[:approved_by].presence || 'web'

      if @agent.approved?
        redirect_to agent_path(@agent), notice: 'Agent is already approved.'
        return
      end

      begin
        @agent.approve!(approved_by: approver)
        redirect_to agent_path(@agent), notice: "Approved by #{approver}. The AI can now invoke this agent via delegate_task."
      rescue ArgumentError, ActiveRecord::RecordInvalid => e
        redirect_to agent_path(@agent), alert: "Could not approve: #{e.message}"
      end
    end

    def diff
      @agent = Agent.find(params[:agent_id])
      @from = @agent.versions.find(params[:from])
      @to   = params[:to].present? ? @agent.versions.find(params[:to]) : nil
      @to_label   = @to ? "Version ##{@to.id}" : 'Current'
      @to_content = @to ? @to.content : @agent.content
    end

    private

    def load_agent
      if params[:id].to_s =~ /\A\d+\z/
        @agent = Agent.find(params[:id])
        return
      end

      # Non-numeric :id — prefer the AR record if a DB row matches by name or slug.
      ar = Agent.where('LOWER(name) = ?', params[:id].to_s.downcase).first
      ar ||= Agent.all.find { |a| slugify(a.name) == params[:id] }
      if ar
        @agent = ar
        return
      end

      all = AgentLoader.new.load_all_agents
      @agent = all.find { |a| slugify(a['name']) == params[:id] || a['name'] == params[:id] }
      raise ActiveRecord::RecordNotFound, "Agent not found: #{params[:id]}" unless @agent
    end

    def agent_params
      { content: params.require(:agent)[:content].to_s }
    end

    def edited_by_param
      params[:edited_by].presence || 'web'
    end

    def new_agent_template
      <<~MD
        ---
        name:
        description:
        max_rounds:
        model:
        tools: []
        ---

        Persona, strategy, rules…
      MD
    end

    def slugify(name)
      name.to_s.downcase.strip
        .gsub(/[^a-z0-9\s-]/, '')
        .gsub(/[\s]+/, '-')
        .gsub(/-+/, '-')
    end

    def read_only_message
      if @agent.is_a?(Hash) && @agent['source'] == :builtin
        'This is a built-in agent shipped with the gem. To customize it, create a same-named DB agent override.'
      else
        'This agent lives on disk under .rails_console_ai/agents/. Edit the file directly to change it.'
      end
    end
  end
end
