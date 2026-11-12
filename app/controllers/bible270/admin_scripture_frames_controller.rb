# frozen_string_literal: true

module Bible270
  class AdminScriptureFramesController < ApplicationController
    before_action :require_admin!
    before_action :require_admin_view!
    before_action :set_reader_sort
    before_action :require_storage!, except: %i[index update_default]
    before_action :load_scripture_frame, only: %i[edit update destroy]

    helper_method :scripture_frames_return_path

    def index
      redirect_to scripture_frames_return_path, status: :see_other
    end

    def update_default
      frame = ScriptureFrames.defaults.find { |entry| entry.id == params[:id] }
      raise ActiveRecord::RecordNotFound unless frame

      unless %w[0 1].include?(params[:enabled])
        return redirect_to scripture_frames_return_path, status: :see_other, alert: 'Choose Enable or Disable. Nothing was changed.'
      end

      enabled = params[:enabled] == '1'
      ScriptureFrames.set_default_enabled!(frame.id, enabled: enabled)
      redirect_to scripture_frames_return_path, status: :see_other, notice: "Default Scripture text #{enabled ? 'enabled' : 'disabled'}."
    rescue ArgumentError => e
      redirect_to scripture_frames_return_path, status: :see_other, alert: e.message
    end

    def new
      @scripture_frame = ScriptureFrame.new(translation: 'NASB95', enabled: true)
    end

    def create
      @scripture_frame = ScriptureFrame.new(scripture_frame_params)
      if @scripture_frame.save
        redirect_to scripture_frames_return_path, status: :see_other, notice: 'Scripture frame added.'
      else
        render :new, status: :unprocessable_entity
      end
    end

    def edit; end

    def update
      @scripture_frame.assign_attributes(scripture_frame_params)
      if @scripture_frame.save
        redirect_to scripture_frames_return_path, status: :see_other, notice: 'Scripture frame saved.'
      else
        render :edit, status: :unprocessable_entity
      end
    end

    def destroy
      @scripture_frame.destroy!
      redirect_to scripture_frames_return_path, status: :see_other, notice: 'Scripture frame deleted.'
    end

  private

    def set_reader_sort
      @reader_sort = AdminController::READER_SORT_OPTIONS.key?(params[:sort]) ? params[:sort] : 'first_name'
    end

    def scripture_frames_return_path
      admin_path(sort: @reader_sort, anchor: 'b270-scripture-frames')
    end

    def require_storage!
      return if ScriptureFrames.custom_available?

      redirect_to scripture_frames_return_path,
                  status: :see_other, alert: 'Custom scripture frames are unavailable until database migrations are run. Nothing was changed.'
    end

    def load_scripture_frame
      # Bundled IDs are not database IDs; reject them before Active Record can coerce them.
      raise ActiveRecord::RecordNotFound unless params[:id].to_s.match?(%r{\A[1-9]\d*\z})

      @scripture_frame = ScriptureFrame.find(params[:id])
    end

    def scripture_frame_params
      params.require(:scripture_frame).permit(:reference, :text, :translation, :enabled)
    end
  end
end
