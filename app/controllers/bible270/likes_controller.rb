# frozen_string_literal: true

module Bible270
  # A heart on someone's reflection. The route accepts the intended state from
  # current forms and retains toggle behavior for cached or external callers.
  class LikesController < ApplicationController
    def toggle
      return unless require_reader!

      @comment = Comment.approved.find_by(id: params[:id])
      head :not_found and return unless @comment

      requested_state = params[:liked] if params.key?(:liked)
      head :bad_request and return if params.key?(:liked) && !%w[0 1].include?(requested_state)

      liked = if requested_state
                @comment.set_like!(current_reader, liked: requested_state == '1')
              else
                @comment.toggle_like!(current_reader)
              end
      @comment.reload

      respond_to do |format|
        format.turbo_stream
        format.html do
          message = liked ? 'Reflection liked.' : 'Like removed.'
          redirect_to day_path(@comment.day, anchor: "comment-#{@comment.id}"),
                      flash: { b270_interaction_status: message }
        end
      end
    end
  end
end
