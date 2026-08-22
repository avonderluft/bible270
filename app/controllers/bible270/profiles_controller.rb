# frozen_string_literal: true

module Bible270
  # A reader editing their own name — the one thing about themselves they can
  # change. Everything else about a reader comes from how they signed in.
  class ProfilesController < ApplicationController
    before_action :require_signed_in_reader

    def edit
      @names = current_reader.suggested_names
      load_comment_notification_state
      load_daily_reminder_state
    end

    def update
      @comment_notifications_available = comment_notifications_available?
      @notify_on_mention = requested_comment_notifications
      @daily_reminders_available = daily_reminders_available?
      problems = []
      problems << 'both a first and last name' unless current_reader.update_names(params[:first_name],
                                                                                  params[:last_name])
      if params[:bible_version].present? && !current_reader.update_bible_version(params[:bible_version])
        problems << 'a translation from the list'
      end
      source = params[:passage_source].presence || Reader::DEFAULT_PASSAGE_SOURCE
      problems << 'a reading-link source from the list' unless current_reader.update_passage_source(source)
      if params[:avatar].present? && !current_reader.attach_avatar(params[:avatar])
        problems << (current_reader.errors[:avatar].first || 'a valid image')
      end

      requested_daily_reminders = params[:daily_reminders] == '1'
      requested_daily_reminder_time = daily_reminder_time_param
      if @daily_reminders_available && !Reader.valid_daily_reminder_time?(requested_daily_reminder_time)
        problems << 'a reminder time in 24-hour HH:MM format'
      end

      if problems.empty?
        current_reader.update!(notify_on_mention: @notify_on_mention) if @comment_notifications_available
        if @daily_reminders_available
          current_reader.update!(daily_reminders: requested_daily_reminders,
                                 daily_reminder_time: requested_daily_reminder_time)
        end
        redirect_to reader_path(current_reader), notice: 'Your profile has been updated.'
      else
        @names = { first_name: params[:first_name], last_name: params[:last_name] }
        @daily_reminders = requested_daily_reminders
        @daily_reminder_time = requested_daily_reminder_time
        flash.now[:alert] = "Please give #{problems.to_sentence}."
        render :edit, status: :unprocessable_entity
      end
    end

    def remove_avatar
      current_reader.remove_avatar!
      redirect_to profile_path, notice: 'Your picture has been removed.'
    end

  private

    def load_comment_notification_state
      @comment_notifications_available = comment_notifications_available?
      @notify_on_mention = current_reader.wants_comment_notifications?
    end

    def comment_notifications_available?
      Bible270.config.mention_notifications && current_reader.has_attribute?(:notify_on_mention)
    end

    def requested_comment_notifications
      return current_reader.wants_comment_notifications? unless params.key?(:notify_on_mention)

      params[:notify_on_mention] == '1'
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

      redirect_to sign_in_path(origin: request.fullpath), alert: 'Please sign in first.'
    end
  end
end
