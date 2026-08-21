# frozen_string_literal: true

module Bible270
  class CheckoffsController < ApplicationController
    def toggle
      return unless require_reader!

      @day   = params[:day].to_i
      @track = params[:track].to_s
      # Part 0 is the first chapter of the reading. Requests without one predate
      # per-chapter check-offs and mean the first part.
      @part  = params[:part].to_i

      head :bad_request and return unless Plan.valid_day?(@day) &&
                                          Plan.present_tracks(@day).include?(@track) &&
                                          Plan.valid_part?(@day, @track, @part)

      requested_state = params[:checked] if params.key?(:checked)
      head :bad_request and return if params.key?(:checked) && !%w[0 1].include?(requested_state)

      marked_read = apply_checkoff(requested_state)

      @reader = current_reader.reload.reload_progress
      @reader_tracks = @reader.read_tracks_for(@day)
      @readings = Plan.readings_for(@day)

      required = Plan.total_parts(@day)
      completer_ids = Checkoff.where(day: @day)
        .group(:reader_id)
        .having('COUNT(*) >= ?', required)
        .pluck(:reader_id)
      @completers = Reader.where(id: completer_ids).order(:display_name)

      respond_to do |format|
        format.turbo_stream
        format.html do
          message = marked_read ? 'Reading marked read.' : 'Reading marked unread.'
          redirect_to day_path(@day), flash: { b270_interaction_status: message }
        end
      end
    end

  private

    def apply_checkoff(requested_state)
      existing = current_reader.checkoffs.find_by(day: @day, track: @track, part: @part)
      if requested_state == '1'
        current_reader.ensure_started!
        current_reader.checkoffs.create_or_find_by!(day: @day, track: @track, part: @part)
        true
      elsif requested_state == '0' || existing
        existing&.destroy
        false
      else
        current_reader.ensure_started!
        current_reader.checkoffs.create(day: @day, track: @track, part: @part)
        true
      end
    end
  end
end
