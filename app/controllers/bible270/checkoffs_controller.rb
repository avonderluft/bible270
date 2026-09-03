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

      # Serialize this reader's transitions so two different final portions
      # submitted concurrently cannot both announce the same day completion.
      marked_read = nil
      current_reader.with_lock do
        marked_read, @completion_event_id = apply_checkoff(requested_state)
        @reader = current_reader.reload.reload_progress
        @day_just_completed = marked_read && @completion_event_id && @reader.day_complete?(@day)
      end
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
          if @day_just_completed
            redirect_to day_path(@day), flash: {
              b270_day_just_completed: @day,
              b270_completion_event_id: @completion_event_id
            }
          else
            message = marked_read ? 'Reading marked read.' : 'Reading marked unread.'
            redirect_to day_path(@day), flash: { b270_interaction_status: message }
          end
        end
      end
    end

  private

    def apply_checkoff(requested_state)
      existing = find_checkoff
      if requested_state == '1'
        current_reader.ensure_started!
        [true, existing.nil? ? create_checkoff : nil]
      elsif requested_state == '0' || existing
        existing&.destroy
        [false, nil]
      else
        current_reader.ensure_started!
        [true, create_checkoff]
      end
    end

    def find_checkoff
      Checkoff.uncached do
        Checkoff.find_by(reader_id: current_reader.id, day: @day, track: @track, part: @part)
      end
    end

    # The created id is stable if Turbo replays this response, while a later
    # re-completion creates a new id and is correctly treated as a new event.
    def create_checkoff
      Checkoff.create!(reader: current_reader, day: @day, track: @track, part: @part).id
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique
      # A repeated or concurrent desired-state request is already successful. Do
      # not hide any other validation failure under the same recovery.
      raise unless find_checkoff

      nil
    end
  end
end
