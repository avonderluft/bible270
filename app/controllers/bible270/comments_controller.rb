# frozen_string_literal: true

module Bible270
  class CommentsController < ApplicationController
    def create
      return unless require_reader!

      @day = params[:day].to_i
      head :bad_request and return unless Plan.valid_day?(@day)

      @comment = current_reader.comments.new(comment_params.merge(day: @day))
      @readings = Plan.readings_for(@day)

      if @comment.save
        respond_to do |format|
          format.turbo_stream
          format.html { redirect_to day_path(@day, anchor: "comment-#{@comment.id}") }
        end
      else
        respond_to do |format|
          format.turbo_stream do
            render turbo_stream: turbo_stream.replace('new_comment_form', partial: 'bible270/comments/form',
                                                                          locals: { day: @day, comment: @comment })
          end
          format.html { redirect_to day_path(@day), alert: @comment.errors.full_messages.to_sentence }
        end
      end
    end

    def update
      return unless require_reader!

      @comment = own_comment
      head :not_found and return unless @comment

      @day = @comment.day
      if @comment.update(comment_params.except(:parent_id))
        respond_to do |format|
          format.turbo_stream
          format.html { redirect_to day_path(@day, anchor: "comment-#{@comment.id}") }
        end
      else
        respond_to do |format|
          format.turbo_stream do
            render turbo_stream: turbo_stream.replace("comment-#{@comment.id}",
                                                      partial: 'bible270/comments/edit_form',
                                                      locals: { comment: @comment })
          end
          format.html { redirect_to day_path(@day), alert: @comment.errors.full_messages.to_sentence }
        end
      end
    end

    def destroy
      return unless require_reader!

      @comment = current_reader.comments.find_by(id: params[:id])
      head :not_found and return unless @comment

      @day = @comment.day
      @comment.destroy
      respond_to do |format|
        format.turbo_stream
        format.html { redirect_to day_path(@day) }
      end
    end

  private

    def comment_params
      params.require(:comment).permit(:body, :track, :parent_id)
    end

    # Scoped to the reader, so someone else's reflection is simply not found —
    # the same shape as destroy, and it reveals nothing about what exists.
    def own_comment
      current_reader.comments.find_by(id: params[:id])
    end
  end
end
