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
          @agent.name        = builtin['name']
          @agent.description = builtin['description']
          @agent.body        = builtin['body']
          @agent.max_rounds  = builtin['max_rounds']
          @agent.model       = builtin['model']
          @agent.tools       = Array(builtin['tools'])
        end
      end
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

    # POST /agents/import — parse a pasted .md blob and re-render `new` with fields prefilled.
    def import
      content = params[:content].to_s
      if content.strip.empty?
        redirect_to new_agent_path, alert: 'Nothing to parse — paste the .md content into the box first.'
        return
      end

      parsed = AgentLoader.parse(content)
      if parsed.nil? || parsed['name'].to_s.strip.empty?
        redirect_to new_agent_path,
                    alert: 'Could not parse. Expected YAML frontmatter (between `---` lines) with at least a `name` field, followed by the agent body.'
        return
      end

      @agent = Agent.new(
        name: parsed['name'],
        description: parsed['description'],
        body: parsed['body'],
        max_rounds: parsed['max_rounds'],
        model: parsed['model']
      )
      @agent.tools = Array(parsed['tools'])

      flash.now[:notice] = "Parsed \"#{parsed['name']}\" from pasted content. Review the fields below and click Create agent to save to the DB."
      render :new
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
      @to_label = @to ? "Version ##{@to.id}" : 'Current'
      @to_body  = @to ? @to.body : @agent.body
      @to_tools = @to ? Array(@to.tools) : Array(@agent.tools)
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
      {
        name:        params.require(:agent)[:name],
        description: params[:agent][:description],
        body:        params[:agent][:body],
        max_rounds:  params[:agent][:max_rounds].presence&.to_i,
        model:       params[:agent][:model].presence,
        tools:       split_lines(params[:agent][:tools])
      }
    end

    def edited_by_param
      params[:edited_by].presence || 'web'
    end

    def split_lines(str)
      str.to_s.split(/[\r\n,]+/).map(&:strip).reject(&:empty?)
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
