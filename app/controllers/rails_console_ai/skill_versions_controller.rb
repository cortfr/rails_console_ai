module RailsConsoleAi
  class SkillVersionsController < RailsConsoleAi::ApplicationController
    before_action :load_skill

    def index
      @versions = @skill.versions
    end

    def show
      @version = @skill.versions.find(params[:id])
    end

    def restore
      version = @skill.versions.find(params[:id])
      @skill.update_with_version!(
        { content: version.content },
        edited_by: params[:edited_by].presence || 'web',
        change_note: "Restored from version ##{version.id}"
      )
      redirect_to skill_path(@skill), notice: "Restored version ##{version.id}."
    end

    private

    def load_skill
      @skill = Skill.find(params[:skill_id])
    end
  end
end
