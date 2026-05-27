require 'rails_console_ai/skill_loader'

module RailsConsoleAi
  class SkillsController < ApplicationController
    before_action :load_skill, only: [:show, :edit, :update, :destroy]

    def index
      @skills = SkillLoader.new.load_all_skills
      @q = params[:q].to_s.strip
      unless @q.empty?
        needle = @q.downcase
        @skills = @skills.select { |s|
          [s['name'], s['description'], Array(s['tags']).join(' ')].compact.join(' ').downcase.include?(needle)
        }
      end
    end

    def show
      @versions = @skill.versions if @skill.is_a?(Skill)
    end

    def new
      @skill = Skill.new
    end

    def create
      @skill = Skill.new
      attrs = skill_params
      begin
        @skill.update_with_version!(
          attrs,
          edited_by: edited_by_param,
          change_note: params[:change_note].presence
        )
        redirect_to skill_path(@skill), notice: 'Skill created.'
      rescue ActiveRecord::RecordInvalid => e
        flash.now[:alert] = e.message
        render :new
      end
    end

    def edit
      redirect_to skills_path, alert: file_skill_message and return unless @skill.is_a?(Skill)
    end

    def update
      redirect_to skills_path, alert: file_skill_message and return unless @skill.is_a?(Skill)

      begin
        @skill.update_with_version!(
          skill_params,
          edited_by: edited_by_param,
          change_note: params[:change_note].presence
        )
        redirect_to skill_path(@skill), notice: 'Skill updated.'
      rescue ActiveRecord::RecordInvalid => e
        flash.now[:alert] = e.message
        render :edit
      end
    end

    def destroy
      if @skill.is_a?(Skill)
        @skill.destroy
        redirect_to skills_path, notice: 'Skill deleted. Past versions remain in history.'
      else
        redirect_to skills_path, alert: file_skill_message
      end
    end

    # GET /skills/diff?skill_id=&from=&to=
    def diff
      @skill = Skill.find(params[:skill_id])
      @from = @skill.versions.find(params[:from])
      @to   = params[:to].present? ? @skill.versions.find(params[:to]) : nil
      # If `to` is omitted, diff against the current skill.
      @to_label = @to ? "Version ##{@to.id}" : 'Current'
      @to_body  = @to ? @to.body : @skill.body
      @to_tags  = @to ? Array(@to.tags) : Array(@skill.tags)
      @to_bypass = @to ? Array(@to.bypass_guards_for_methods) : Array(@skill.bypass_guards_for_methods)
    end

    private

    def load_skill
      # /skills/:id supports both DB ids and file slugs. Numeric -> DB; else file lookup.
      if params[:id].to_s =~ /\A\d+\z/
        @skill = Skill.find(params[:id])
      else
        all = SkillLoader.new.load_all_skills
        @skill = all.find { |s| slugify(s['name']) == params[:id] || s['name'] == params[:id] }
        raise ActiveRecord::RecordNotFound, "Skill not found: #{params[:id]}" unless @skill
      end
    end

    def skill_params
      {
        name:                       params.require(:skill)[:name],
        description:                params[:skill][:description],
        body:                       params[:skill][:body],
        tags:                       split_csv(params[:skill][:tags]),
        bypass_guards_for_methods:  split_lines(params[:skill][:bypass_guards_for_methods])
      }
    end

    def edited_by_param
      params[:edited_by].presence || 'web'
    end

    def split_csv(str)
      str.to_s.split(',').map(&:strip).reject(&:empty?)
    end

    def split_lines(str)
      str.to_s.split(/[\r\n]+/).map(&:strip).reject(&:empty?)
    end

    def slugify(name)
      name.to_s.downcase.strip
        .gsub(/[^a-z0-9\s-]/, '')
        .gsub(/[\s]+/, '-')
        .gsub(/-+/, '-')
    end

    def file_skill_message
      'This skill lives on disk under .rails_console_ai/skills/. Edit the file directly to change it.'
    end
  end
end
