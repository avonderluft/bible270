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

      existing = current_reader.checkoffs.find_by(day: @day, track: @track, part: @part)
      if existing
        existing.destroy
      else
        current_reader.ensure_started!
        current_reader.checkoffs.create(day: @day, track: @track, part: @part)
      end

      @reader = current_reader.reload
      @reader_tracks = @reader.read_tracks_for(@day)
      @readings = Plan.readings_for(@day)

      respond_to do |format|
        format.turbo_stream
        format.html { redirect_to day_path(@day) }
      end
    end
  end
end
