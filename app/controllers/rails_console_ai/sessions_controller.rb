module RailsConsoleAi
  class SessionsController < ApplicationController
    PER_PAGE = 50

    def index
      @page = [params[:page].to_i, 1].max
      @total = Session.count
      @total_pages = (@total / PER_PAGE.to_f).ceil
      @sessions = Session.recent.offset((@page - 1) * PER_PAGE).limit(PER_PAGE)
    end

    def show
      @session = Session.find(params[:id])
    end
  end
end
