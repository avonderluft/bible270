# frozen_string_literal: true

module Bible270
  # A heart on someone's reflection. One route, because liking and unliking are
  # the same gesture — tapping the heart again takes it back.
  class LikesController < ApplicationController
    def toggle
      return unless require_reader!

      @comment = Comment.approved.find_by(id: params[:id])
      head :not_found and return unless @comment

      @comment.toggle_like!(current_reader)
      @comment.reload

      respond_to do |format|
        format.turbo_stream
        format.html { redirect_to day_path(@comment.day, anchor: "comment-#{@comment.id}") }
      end
    end
  end
end
