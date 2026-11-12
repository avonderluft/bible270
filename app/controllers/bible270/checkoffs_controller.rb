# frozen_string_literal: true

module Bible270
  class CheckoffsController < ApplicationController
    def toggle
      return unless require_reader!
      return archived_progress if current_reader.alumni?

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

      marked_read = persist_checkoff(requested_state)
      @reader_tracks = @reader.read_tracks_for(@day)
      @readings = Plan.readings_for(@day)

      @completers = Reader.completers_for(@day)

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
    rescue Participation::ArchivedProgress
      archived_progress
    rescue PlanRun::StaleRun
      respond_to do |format|
        format.turbo_stream { head :conflict }
        format.html { redirect_to day_path(@day), alert: 'Your plan run changed. Reload the page before updating progress.' }
      end
    end

  private

    def archived_progress
      respond_to do |format|
        format.turbo_stream { head :forbidden }
        format.html { redirect_to root_path, alert: 'Alumni progress is read-only. An admin can add you to the current run.' }
      end
    end

    def persist_checkoff(requested_state)
      marked_read = nil
      membership = current_reader.participation
      # Serialize completion events and match restart's run-then-reader lock order.
      membership.plan_run.with_lock do
        current_reader.with_lock do
          current_reader.reload_progress
          unless current_reader.participation.id == membership.id &&
                 (!params.key?(:participation_id) || params[:participation_id].to_s == membership.id.to_s)
            raise PlanRun::StaleRun
          end

          current_reader.ensure_progress_writable!
          marked_read, @completion_event_id = apply_checkoff(requested_state)
          @reader = current_reader.reload.reload_progress
          @day_just_completed = marked_read && @completion_event_id && @reader.day_complete?(@day)
        end
      end
      marked_read
    end

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
        current_reader.checkoffs.find_by(day: @day, track: @track, part: @part)
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
