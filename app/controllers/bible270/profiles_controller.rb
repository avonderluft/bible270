# frozen_string_literal: true

module Bible270
  # A reader editing their own name — the one thing about themselves they can
  # change. Everything else about a reader comes from how they signed in.
  class ProfilesController < ApplicationController
    before_action :require_signed_in_reader

    def edit
      @names = current_reader.suggested_names
    end

    def update
      problems = []
      problems << 'both a first and last name' unless current_reader.update_names(params[:first_name],
                                                                                  params[:last_name])
      if params[:avatar].present? && !current_reader.attach_avatar(params[:avatar])
        problems << (current_reader.errors[:avatar].first || 'a valid image')
      end

      if problems.empty?
        redirect_to reader_path(current_reader), notice: 'Your profile has been updated.'
      else
        @names = { first_name: params[:first_name], last_name: params[:last_name] }
        flash.now[:alert] = "Please give #{problems.to_sentence}."
        render :edit, status: :unprocessable_entity
      end
    end

    def remove_avatar
      current_reader.remove_avatar!
      redirect_to profile_path, notice: 'Your picture has been removed.'
    end

  private

    # Unlike checking off a reading, there is nothing sensible to do here for a
    # visitor who isn't signed in, so send them to sign in rather than 404.
    def require_signed_in_reader
      return if signed_in?

      redirect_to sign_in_path(origin: request.fullpath), alert: 'Please sign in first.'
    end
  end
end
