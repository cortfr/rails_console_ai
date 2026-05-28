module RailsConsoleAi
  class AgentVersionsController < ApplicationController
    before_action :load_agent

    def index
      @versions = @agent.versions
    end

    def show
      @version = @agent.versions.find(params[:id])
    end

    def restore
      version = @agent.versions.find(params[:id])
      @agent.update_with_version!(
        {
          name:        version.name,
          description: version.description,
          body:        version.body,
          max_rounds:  version.max_rounds,
          model:       version.model,
          tools:       Array(version.tools)
        },
        edited_by: params[:edited_by].presence || 'web',
        change_note: "Restored from version ##{version.id}"
      )
      redirect_to agent_path(@agent), notice: "Restored version ##{version.id}."
    end

    private

    def load_agent
      @agent = Agent.find(params[:agent_id])
    end
  end
end
