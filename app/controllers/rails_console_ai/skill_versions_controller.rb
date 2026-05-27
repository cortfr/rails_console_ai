module RailsConsoleAi
  class SkillVersionsController < ApplicationController
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
        {
          name:                      version.name,
          description:               version.description,
          body:                      version.body,
          tags:                      Array(version.tags),
          bypass_guards_for_methods: Array(version.bypass_guards_for_methods)
        },
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
