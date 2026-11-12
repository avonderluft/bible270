# frozen_string_literal: true

module Bible270
  class AdminScriptureFramesController < ApplicationController
    before_action :require_admin!
    before_action :require_admin_view!
    before_action :require_storage!, except: :index
    before_action :load_scripture_frame, only: %i[edit update destroy]

    def index
      @defaults = ScriptureFrames.defaults
      @storage_available = ScriptureFrames.custom_available?
      @scripture_frames = @storage_available ? ScriptureFrame.order(:id) : []
    end

    def new
      @scripture_frame = ScriptureFrame.new(translation: 'NASB95', enabled: true)
    end

    def create
      @scripture_frame = ScriptureFrame.new(scripture_frame_params)
      if @scripture_frame.save
        redirect_to admin_scripture_frames_path, status: :see_other, notice: 'Scripture frame added.'
      else
        render :new, status: :unprocessable_entity
      end
    end

    def edit; end

    def update
      @scripture_frame.assign_attributes(scripture_frame_params)
      if @scripture_frame.save
        redirect_to admin_scripture_frames_path, status: :see_other, notice: 'Scripture frame saved.'
      else
        render :edit, status: :unprocessable_entity
      end
    end

    def destroy
      @scripture_frame.destroy!
      redirect_to admin_scripture_frames_path, status: :see_other, notice: 'Scripture frame deleted.'
    end

  private

    def require_storage!
      return if ScriptureFrames.custom_available?

      redirect_to admin_scripture_frames_path,
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
