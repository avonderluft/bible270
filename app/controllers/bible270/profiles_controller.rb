# frozen_string_literal: true

module Bible270
  # A reader editing their own details and preferences.
  class ProfilesController < ApplicationController
    before_action :require_signed_in_reader

    def edit
      @names = current_reader.suggested_names
      @display_mode = current_reader.effective_display_mode
      load_comment_notification_state
      load_daily_reminder_state
    end

    def update
      @comment_notifications_available = comment_notifications_available?
      @comment_notification_level = requested_comment_notification_level
      @daily_reminders_available = daily_reminders_available?
      @display_mode = params.fetch(:display_mode, current_reader.effective_display_mode).to_s
      @names = { first_name: params[:first_name], last_name: params[:last_name] }
      @daily_reminders = params[:daily_reminders] == '1'
      @daily_reminder_time = daily_reminder_time_param
      names = Names.normalize(params[:first_name], params[:last_name])
      source = (params[:passage_source].presence || Reader::DEFAULT_PASSAGE_SOURCE).to_s
      problems = [comment_notification_problem, display_mode_problem, avatar_problem].compact
      problems << 'both a first and last name' unless names
      if params[:bible_version].present? && !Translations.valid?(params[:bible_version])
        problems << 'a translation from the list'
      end
      problems << 'a reading-link source from the list' unless Reader::PASSAGE_SOURCES.include?(source)
      if @daily_reminders_available && !Reader.valid_daily_reminder_time?(@daily_reminder_time)
        problems << 'a reminder time in 24-hour HH:MM format'
      end
      return render_profile_error("Please give #{problems.to_sentence}.") if problems.any?

      save_profile(names.merge(passage_source: source))
      redirect_to profile_path, notice: 'Your profile has been updated.'
    rescue AvatarOptimizer::Error, AvatarImages::Error => e
      current_reader.attachment_changes.clear if Reader.avatar_uploads?
      current_reader.reload
      render_profile_error(e.message)
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotSaved => e
      message = e.record ? e.record.errors.full_messages.to_sentence : nil
      # Reload does not discard Active Storage's deferred attachment changes.
      current_reader.attachment_changes.clear if Reader.avatar_uploads?
      current_reader.reload
      render_profile_error("Your profile could not be saved. #{message.presence || 'Please try again.'}")
    end

    def update_theme
      unless Reader.display_mode_column?
        return render_theme_error('Run the pending Bible270 database migration before changing the theme.')
      end

      mode = params[:display_mode].to_s
      return render_theme_error('Choose a theme from the list.') unless Reader::DISPLAY_MODES.include?(mode)

      current_reader.reload unless current_reader.has_attribute?(:display_mode)
      current_reader.update!(display_mode: mode)
      respond_to do |format|
        format.json { render json: { display_mode: current_reader.display_mode } }
        format.html { redirect_to profile_path, notice: 'Theme updated.' }
      end
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotSaved => e
      message = e.record ? e.record.errors.full_messages.to_sentence : nil
      render_theme_error("Your theme could not be saved. #{message.presence || 'Please try again.'}")
    end

    def remove_avatar
      current_reader.remove_avatar!
      redirect_to profile_path, notice: 'Your picture has been removed.'
    end

  private

    def render_theme_error(message)
      respond_to do |format|
        format.json { render json: { error: message }, status: :unprocessable_entity }
        format.html { redirect_to profile_path, alert: message }
      end
    end

    def display_mode_problem
      return unless Reader.display_mode_column?
      return if Reader::DISPLAY_MODES.include?(@display_mode)

      'a theme from the list'
    end

    def avatar_problem
      upload = params[:avatar]
      return if upload.blank?
      return 'a valid image' unless Reader.avatar_uploads?

      Avatars.problem_with(content_type: upload.content_type, byte_size: upload.size)
    end

    def save_profile(attributes)
      attributes[:bible_version] = Translations.normalize(params[:bible_version]) if params[:bible_version].present?
      attributes[:display_mode] = @display_mode if Reader.display_mode_column?
      if @comment_notifications_available
        attributes[:notify_on_mention] = @comment_notification_level != 'none'
        attributes[:notify_on_all_comments] = @comment_notification_level == 'all'
      end
      if @daily_reminders_available
        attributes[:daily_reminders] = @daily_reminders
        attributes[:daily_reminder_time] = @daily_reminder_time
      end

      AvatarImages.update!(current_reader, attributes, upload: params[:avatar].presence)
    end

    def render_profile_error(message)
      flash.now[:alert] = message
      render :edit, status: :unprocessable_entity
    end

    def load_comment_notification_state
      @comment_notifications_available = comment_notifications_available?
      @comment_notification_level = current_reader.comment_notification_level
    end

    def comment_notifications_available?
      return false unless Bible270.config.mention_notifications && Reader.comment_notification_columns?

      current_reader.reload unless current_reader.has_attribute?(:notify_on_all_comments)
      true
    end

    def requested_comment_notification_level
      return current_reader.comment_notification_level unless params.key?(:comment_notifications)

      params[:comment_notifications].to_s
    end

    def comment_notification_problem
      return unless @comment_notifications_available
      return if Reader::COMMENT_NOTIFICATION_LEVELS.include?(@comment_notification_level)

      'a reflection email preference from the list'
    end

    def load_daily_reminder_state
      @daily_reminders_available = daily_reminders_available?
      if @daily_reminders_available
        @daily_reminders = current_reader.daily_reminders
        @daily_reminder_time = current_reader.daily_reminder_time
      else
        @daily_reminders = false
        @daily_reminder_time = '08:00'
      end
    end

    def daily_reminders_available?
      Bible270.config.daily_reminders? && Reader.daily_reminder_columns?
    end

    def daily_reminder_time_param
      hour = params[:daily_reminder_hour]
      minute = params[:daily_reminder_minute]
      return "#{hour}:#{minute}" if hour.present? || minute.present?

      params[:daily_reminder_time].to_s
    end

    # Unlike checking off a reading, there is nothing sensible to do here for a
    # visitor who isn't signed in, so send them to sign in rather than 404.
    def require_signed_in_reader
      return if signed_in?
      if action_name == 'update_theme' && request.format.json?
        return render_theme_error('Please sign in first.')
      end

      redirect_to sign_in_path(origin: request.fullpath), alert: 'Please sign in first.'
    end
  end
end
