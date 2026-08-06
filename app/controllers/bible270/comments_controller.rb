# frozen_string_literal: true

module Bible270
  class CommentsController < ApplicationController
    def index
      @days_with_reflections = Comment.approved.distinct.pluck(:day).sort
      @threads = recent_threads
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

    # The most recently active conversations, newest first. A reply counts as
    # activity, so answering an old reflection brings the whole thread back up —
    # otherwise a lively discussion on day 3 would stay buried while quieter, newer
    # reflections sat above it.
    def recent_threads
      wanted = Bible270.config.reflections_page_size.to_i
      wanted = 10 unless wanted.positive?

      # Look at rather more messages than threads, since several may belong to one.
      recent = Comment.approved.order(created_at: :desc).limit(wanted * 5)
        .pluck(:id, :parent_id, :created_at)

      roots = {}
      recent.each do |id, parent_id, created_at|
        root = parent_id || id
        roots[root] ||= created_at
        roots[root] = created_at if created_at > roots[root]
      end

      ids = roots.sort_by { |_root, at| -at.to_i }.first(wanted).map(&:first)
      threads = Comment.approved.where(id: ids)
        .includes(:reader, { likes: :reader }, { replies: [:reader, { likes: :reader }] })
        .index_by(&:id)
      ids.filter_map { |id| threads[id] }
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
