# frozen_string_literal: true

module Bible270
  class CommentsController < ApplicationController
    def index
      visited_at = Time.current
      @days_with_reflections = Comment.approved.distinct.pluck(:day).sort
      load_reflection_filters
      load_reflection_page
      load_new_reflections
      current_reader&.mark_reflections_seen!(visited_at)
    end

    def create
      return unless require_reader!

      @day = params[:day].to_i
      head :bad_request and return unless Plan.valid_day?(@day)

      @comment = current_reader.comments.new(comment_params.merge(day: @day))
      @readings = Plan.readings_for(@day)

      if @comment.save
        respond_to do |format|
          format.turbo_stream
          format.html do
            message = @comment.reply? ? 'Reply posted.' : 'Reflection posted.'
            redirect_to day_path(@day, anchor: "comment-#{@comment.id}"),
                        flash: { b270_interaction_status: message }
          end
        end
      else
        respond_to do |format|
          format.turbo_stream do
            render turbo_stream: turbo_stream.replace('new_comment_form', partial: 'bible270/comments/form',
                                                                          locals: { day: @day, comment: @comment }),
                   status: :unprocessable_entity
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
          format.html do
            redirect_to day_path(@day, anchor: "comment-#{@comment.id}"),
                        flash: { b270_interaction_status: 'Changes saved.' }
          end
        end
      else
        respond_to do |format|
          format.turbo_stream do
            render turbo_stream: turbo_stream.replace("comment-#{@comment.id}",
                                                      partial: 'bible270/comments/edit_form',
                                                      locals: { comment: @comment }),
                   status: :unprocessable_entity
          end
          format.html { redirect_to day_path(@day), alert: @comment.errors.full_messages.to_sentence }
        end
      end
    end

    def destroy
      return unless require_reader!

      @comment = deletable_comment
      head :not_found and return unless @comment

      @day = @comment.day
      @comment.destroy
      respond_to do |format|
        format.turbo_stream
        format.html { redirect_to day_path(@day) }
      end
    end

  private

    def load_reflection_filters
      root_reflections = Comment.approved.where(parent_id: nil)
      reader_ids = root_reflections.distinct.pluck(:reader_id)
      @reflection_readers = Reader.where(id: reader_ids).to_a.sort_by(&:sort_name)

      requested_day = params[:day].presence&.to_i
      @reflection_day = requested_day if @days_with_reflections.include?(requested_day)

      requested_reader = params[:reader_id].presence&.to_i
      @reflection_reader_id = requested_reader if reader_ids.include?(requested_reader)
    end

    def load_reflection_page
      result = Comment.thread_page(
        day: @reflection_day,
        reader_id: @reflection_reader_id,
        page: params[:page],
        per_page: Bible270.config.reflections_page_size
      )
      @threads = result.threads
      @thread_activity = result.activity_by_id
      @reflection_page = result.page
      @reflection_pages = result.pages
      @reflection_total = result.total
    end

    def load_new_reflections
      @reflections_since = reflections_since
      @reflections_since_param = @reflections_since&.iso8601(6) || 'none'
      @new_thread_ids = if @reflections_since
                          @thread_activity.filter_map do |id, activity_at|
                            id if activity_at > @reflections_since
                          end
                        else
                          []
                        end
    end

    def reflections_since
      return nil unless current_reader&.class&.reflections_seen_column?
      return current_reader.reflections_seen_at unless params.key?(:since)
      return nil if params[:since] == 'none'

      Time.iso8601(params[:since].to_s)
    rescue ArgumentError
      current_reader.reflections_seen_at
    end

    def comment_params
      params.require(:comment).permit(:body, :track, :parent_id)
    end

    # Scoped to the reader, so someone else's reflection is simply not found —
    # it reveals nothing about what exists.
    def own_comment
      current_reader.comments.find_by(id: params[:id])
    end

    # An admin may remove any reflection; everyone else only their own. Editing
    # stays with the writer either way.
    def deletable_comment
      return own_comment unless Bible270.config.admin?(current_reader)

      Comment.find_by(id: params[:id])
    end
  end
end
