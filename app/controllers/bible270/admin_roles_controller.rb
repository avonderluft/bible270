# frozen_string_literal: true

module Bible270
  class AdminRolesController < ApplicationController
    before_action :require_site_admin!

    protect_from_forgery with: :exception
    self.forgery_protection_origin_check = true
    rescue_from ActionController::InvalidAuthenticityToken, with: :hide_role_endpoint

    def update
      target = Reader.find(params[:id])

      if Bible270.config.site_admin?(target)
        redirect_to admin_reader_path(target),
                    status: :see_other, alert: 'Site-admin roles are controlled by configuration. Nothing was changed.'
      elsif !%w[admin reader].include?(params[:role])
        redirect_to admin_reader_path(target),
                    status: :see_other, alert: 'Choose admin or reader. Nothing was changed.'
      elsif !target.has_attribute?(:admin)
        redirect_to admin_reader_path(target),
                    status: :see_other, alert: 'Admin roles are unavailable until database migrations are run. Nothing was changed.'
      else
        target.with_lock do
          target.admin = params[:role] == 'admin'
          target.save!
        end
        redirect_to admin_reader_path(target),
                    status: :see_other, notice: target.admin? ? 'Admin access granted.' : 'Admin access removed.'
      end
    end

  private

    def require_site_admin!
      return if b270_site_admin? && b270_admin_view?

      hide_role_endpoint
    end

    # Role changes must not use the ordinary stale-page recovery redirect.
    def handle_unverified_request
      hide_role_endpoint
    end

    def hide_role_endpoint
      raise ActionController::RoutingError, 'Not Found'
    end
  end
end
