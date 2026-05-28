require 'rails_console_ai/skill_loader'

module RailsConsoleAi
  class SkillsController < ApplicationController
    before_action :load_skill, only: [:show, :edit, :update, :destroy, :approve]

    def index
      @skills = SkillLoader.new.load_all_skills
      @q = params[:q].to_s.strip
      unless @q.empty?
        needle = @q.downcase
        @skills = @skills.select { |s|
          [s['name'], s['description'], Array(s['tags']).join(' ')].compact.join(' ').downcase.include?(needle)
        }
      end

      @sort = params[:sort].to_s
      if @sort == 'used'
        # Most-used first; file/builtin records (no counter) sink to the bottom alphabetically.
        @skills = @skills.sort_by { |s| [-(s['use_count'].to_i), s['name'].to_s.downcase] }
      end
    end

    def show
      @versions = @skill.versions if @skill.is_a?(RailsConsoleAi::Skill)
    end

    def new
      @skill = Skill.new
    end

    # POST /skills/import — accepts a pasted .md blob in params[:content], parses
    # YAML frontmatter + body, and re-renders `new` with the fields pre-populated.
    # The user reviews + clicks Create skill to actually persist (normal proposed-
    # status + version-row flow applies).
    def import
      content = params[:content].to_s
      if content.strip.empty?
        redirect_to new_skill_path, alert: 'Nothing to parse — paste the .md content into the box first.'
        return
      end

      parsed = SkillLoader.parse(content)
      if parsed.nil? || parsed['name'].to_s.strip.empty?
        redirect_to new_skill_path,
                    alert: 'Could not parse. Expected YAML frontmatter (between `---` lines) with at least a `name` field, followed by a markdown body.'
        return
      end

      @skill = Skill.new(
        name: parsed['name'],
        description: parsed['description'],
        body: parsed['body']
      )
      @skill.tags = Array(parsed['tags'])
      @skill.bypass_guards_for_methods = Array(parsed['bypass_guards_for_methods'])

      flash.now[:notice] = "Parsed \"#{parsed['name']}\" from pasted content. Review the fields below and click Create skill to save to the DB."
      render :new
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
      redirect_to skills_path, alert: file_skill_message and return unless @skill.is_a?(RailsConsoleAi::Skill)
    end

    def update
      redirect_to skills_path, alert: file_skill_message and return unless @skill.is_a?(RailsConsoleAi::Skill)

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
      if @skill.is_a?(RailsConsoleAi::Skill)
        @skill.destroy
        redirect_to skills_path, notice: 'Skill deleted. Past versions remain in history.'
      else
        redirect_to skills_path, alert: file_skill_message
      end
    end

    def approve
      redirect_to skills_path, alert: file_skill_message and return unless @skill.is_a?(RailsConsoleAi::Skill)

      approver = params[:approved_by].presence ||
                 (request.respond_to?(:remote_user) && request.remote_user.presence) ||
                 'web'

      if @skill.approved?
        redirect_to skill_path(@skill), notice: 'Skill is already approved.'
        return
      end

      begin
        @skill.approve!(approved_by: approver)
        redirect_to skill_path(@skill), notice: "Approved by #{approver}. The AI can now activate this skill."
      rescue ArgumentError, ActiveRecord::RecordInvalid => e
        redirect_to skill_path(@skill), alert: "Could not approve: #{e.message}"
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
      # /skills/:id supports DB ids and file slugs/names. For DB-sourced records we
      # always return the AR record so write actions (update/destroy/approve) can
      # operate on it; for file-sourced records we return the loaded Hash (view-only).
      if params[:id].to_s =~ /\A\d+\z/
        @skill = Skill.find(params[:id])
        return
      end

      # Non-numeric :id — could be a DB-backed name/slug OR a file-only name.
      # Try the DB by name first; fall back to the union (which surfaces file skills).
      ar = Skill.where('LOWER(name) = ?', params[:id].to_s.downcase).first
      if ar.nil?
        # Maybe the URL has a slugified name (spaces → hyphens, punctuation stripped).
        ar = Skill.all.find { |s| slugify(s.name) == params[:id] }
      end
      if ar
        @skill = ar
        return
      end

      all = SkillLoader.new.load_all_skills
      @skill = all.find { |s| slugify(s['name']) == params[:id] || s['name'] == params[:id] }
      raise ActiveRecord::RecordNotFound, "Skill not found: #{params[:id]}" unless @skill
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
