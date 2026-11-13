# frozen_string_literal: true

module Bible270
  class ScriptureFramesController < ApplicationController
    def show
      response.set_header('Cache-Control', 'no-store')
      return head :not_acceptable unless request.format.json?

      exclude = params[:exclude] if params[:exclude].is_a?(String)
      frame = ScriptureFrames.random(exclude: exclude)
      return head :no_content unless frame

      render json: frame.to_h
    end
  end
end
