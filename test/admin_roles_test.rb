# frozen_string_literal: true

require 'test_helper'

if RAILS_LOADED
  class AdminRolesTest < ActionDispatch::IntegrationTest
    def setup
      needs_rails!
      clear_engine_tables!
      @previous_config = %i[
        admin_emails admin_resolver current_reader_resolver registration_notice_deliver_later
      ].to_h { |key| [key, Bible270.config.public_send(key)] }
      Bible270.config.admin_resolver = nil
      Bible270.config.current_reader_resolver = nil
      Bible270.config.registration_notice_deliver_later = false
      @site_admin = create_reader('site-admin')
      @admin = create_reader('admin', admin: true)
      @reader = create_reader('reader')
      Bible270.config.admin_emails = [@site_admin.email]
    end

    def teardown
      @previous_config&.each { |key, value| Bible270.config.public_send("#{key}=", value) }
    end

    def test_admin_column_is_a_non_nullable_boolean_defaulting_to_false
      column = Bible270::Reader.columns_hash.fetch('admin')

      assert_equal :boolean, column.type
      refute column.null
      refute @reader.reload.admin?
      assert_raises(ActiveRecord::NotNullViolation) { @reader.update_column(:admin, nil) }
    end

    def test_site_admin_can_grant_and_remove_admin_access_with_explicit_roles
      sign_in_as(@site_admin)

      %w[admin admin reader reader].each do |role|
        change_role(@reader, role)

        assert_response :see_other
        assert_redirected_to reader_path(@reader)
        assert_equal role == 'admin', @reader.reload.admin?
        assert flash[:notice].present?
        refute Bible270.config.site_admin?(@reader)
      end
    end

    def test_grants_and_revocation_take_effect_on_the_next_request_in_an_existing_session
      browser = open_session
      sign_in_as(@reader, browser: browser)
      browser.get "#{mount}/admin"
      browser.assert_response :not_found
      sign_in_as(@site_admin)

      change_role(@reader, 'admin')
      assert_response :see_other
      browser.get "#{mount}/admin"
      browser.assert_response :success
      browser.patch "#{mount}/admin/view", params: { view: 'reader' }
      browser.assert_response :see_other

      change_role(@reader, 'reader')
      assert_response :see_other
      browser.get "#{mount}/admin"
      browser.assert_response :not_found
      browser.patch "#{mount}/admin/view", params: { view: 'admin' }
      browser.assert_response :not_found
      browser.patch role_path(@site_admin), params: { role: 'reader' }
      browser.assert_response :not_found
      refute @reader.reload.admin?
    end

    def test_a_stored_admin_keeps_access_without_any_configured_admins
      Bible270.config.admin_emails = []
      refute Bible270.config.admin_configured?
      sign_in_as(@admin)

      get "#{mount}/admin"
      assert_response :success
      get reader_path(@reader)
      assert_response :success
      assert_select "a[href='#{mount}/admin']"

      change_role(@reader, 'admin')
      assert_response :not_found
      refute @reader.reload.admin?
    end

    def test_a_false_resolver_does_not_disable_stored_admin_access
      Bible270.config.admin_resolver = ->(_reader) { false }
      sign_in_as(@admin)

      get "#{mount}/admin"
      assert_response :success
      change_role(@reader, 'admin')
      assert_response :not_found
      refute @reader.reload.admin?
    end

    def test_a_resolver_site_admin_can_manage_roles_without_matching_any_email
      Bible270.config.admin_emails = []
      Bible270.config.admin_resolver = ->(reader) { reader.id == @site_admin.id }
      sign_in_as(@site_admin)

      change_role(@reader, 'admin')

      assert_response :see_other
      assert @reader.reload.admin?
    end

    def test_a_resolver_denial_overrides_a_listed_site_admin_even_with_an_ordinary_grant
      @site_admin.update!(admin: true)
      Bible270.config.admin_resolver = ->(_reader) { false }
      sign_in_as(@site_admin)

      change_role(@reader, 'admin')

      assert_response :not_found
      refute @reader.reload.admin?
    end

    def test_email_site_admins_cannot_be_granted_or_demoted_including_self
      other = create_reader('other-site-admin', admin: true)
      Bible270.config.admin_emails = [@site_admin.email.upcase, other.email.upcase]
      sign_in_as(@site_admin)

      [@site_admin, other].each do |target|
        %w[admin reader].each do |role|
          before = target.reload.attributes
          change_role(target, role)

          assert_response :see_other
          assert_redirected_to reader_path(target)
          assert_match(%r{configuration}, flash[:alert])
          assert_equal before, target.reload.attributes
        end
      end
    end

    def test_a_resolver_site_admin_target_is_protected
      Bible270.config.admin_emails = []
      Bible270.config.admin_resolver = ->(reader) { [@site_admin.id, @reader.id].include?(reader.id) }
      sign_in_as(@site_admin)

      %w[admin reader].each do |role|
        change_role(@reader, role)

        assert_response :see_other
        assert flash[:alert].present?
        refute @reader.reload.admin?
      end
    end

    def test_a_listed_reader_denied_by_the_resolver_is_not_a_protected_site_admin
      Bible270.config.admin_emails = [@reader.email]
      Bible270.config.admin_resolver = ->(reader) { reader.id == @site_admin.id }
      sign_in_as(@site_admin)

      change_role(@reader, 'admin')

      assert_response :see_other
      assert @reader.reload.admin?
      refute Bible270.config.site_admin?(@reader)
    end

    def test_target_is_loaded_fresh_before_checking_site_admin_protection
      sign_in_as(@site_admin)
      Bible270::Reader.where(id: @reader.id).update_all(email: @site_admin.email)
      refute_equal @reader.email, @site_admin.email

      change_role(@reader, 'admin')

      assert_response :see_other
      assert flash[:alert].present?
      refute @reader.reload.admin?
    end

    def test_invalid_and_missing_roles_do_not_change_any_attributes
      sign_in_as(@site_admin)
      [nil, '', 'site-admin', 'ADMIN', 'true', 'false', '0', '1', ['admin'], { name: 'admin' }].each do |role|
        before = @reader.reload.attributes
        change_role(@reader, role)

        assert_response :see_other
        assert_redirected_to reader_path(@reader)
        assert flash[:alert].present?
        assert_equal before, @reader.reload.attributes
      end
    end

    def test_role_changes_never_mass_assign_other_submitted_attributes
      sign_in_as(@site_admin)
      before = @reader.attributes.except('admin', 'updated_at')
      patch role_path(@reader), params: {
        role: 'admin', email: @site_admin.email, display_name: 'Forged', started_on: '1900-01-01',
        reader: { admin: true, email: @site_admin.email, display_name: 'Forged' }
      }

      assert_response :see_other
      assert @reader.reload.admin?
      assert_equal before, @reader.attributes.except('admin', 'updated_at')

      patch role_path(@reader), params: { role: 'reader', admin: true, reader: { admin: true } }
      assert_response :see_other
      refute @reader.reload.admin?
    end

    def test_visitors_cannot_forge_grants_or_demotions
      assert_role_requests_hidden
    end

    def test_ordinary_readers_cannot_forge_grants_or_demotions
      sign_in_as(@reader)
      assert_role_requests_hidden
    end

    def test_ordinary_admins_cannot_forge_grants_or_demotions
      sign_in_as(@admin)
      assert_role_requests_hidden
    end

    def test_preview_site_admins_cannot_forge_grants_or_demotions
      sign_in_as(@site_admin)
      patch "#{mount}/admin/view", params: { view: 'reader' }
      assert_response :see_other
      assert_role_requests_hidden

      patch "#{mount}/admin/view", params: { view: 'admin' }
      assert_response :see_other
      change_role(@reader, 'admin')
      assert_response :see_other
      assert @reader.reload.admin?
    end

    def test_an_authorized_request_for_a_missing_reader_is_hidden
      sign_in_as(@site_admin)
      patch "#{mount}/admin/readers/0/role", params: { role: 'admin' }

      assert_response :not_found
    end

    def test_missing_and_invalid_csrf_tokens_are_rejected_without_changing_roles
      with_forgery_protection do
        sign_in_as(@site_admin)
        [nil, 'forged-token'].each do |token|
          patch role_path(@reader), params: { role: 'admin', authenticity_token: token }

          assert_response :not_found
          refute @reader.reload.admin?
        end
      end
    end

    def test_cross_origin_requests_are_rejected_even_with_a_valid_csrf_token
      with_forgery_protection do
        sign_in_as(@site_admin)
        token = csrf_token
        ['https://attacker.example', 'null'].each do |origin|
          patch role_path(@reader), params: { role: 'admin', authenticity_token: token },
                                    headers: { 'Origin' => origin }

          assert_response :not_found
          refute @reader.reload.admin?
        end
      end
    end

    def test_a_same_origin_request_with_a_valid_csrf_token_can_change_roles
      with_forgery_protection do
        sign_in_as(@site_admin)
        token = csrf_token
        patch role_path(@reader), params: { role: 'admin', authenticity_token: token },
                                  headers: { 'Origin' => request.base_url }

        assert_response :see_other
        assert @reader.reload.admin?
      end
    end

    def test_a_reader_without_the_admin_attribute_fails_closed
      reader = Bible270::Reader.select(:id, :email).find(@reader.id)

      refute Bible270.config.admin?(reader)
      Bible270.config.admin_emails = [reader.email]
      assert Bible270.config.site_admin?(reader)
      assert Bible270.config.admin?(reader)
    end

    def test_role_changes_fail_safely_if_the_admin_migration_is_pending
      sign_in_as(@site_admin)
      target = @reader.reload
      original = target.method(:has_attribute?)
      without_admin = ->(name) { name.to_s != 'admin' && original.call(name) }
      Bible270::Reader.stub(:find, target) do
        target.stub(:has_attribute?, without_admin) { change_role(@reader, 'admin') }
      end

      assert_response :see_other
      assert_redirected_to reader_path(@reader)
      assert_match(%r{migrations}, flash[:alert])
      refute @reader.reload.admin?
    end

    def test_alumni_can_receive_and_lose_roles_without_reactivation_or_losing_sign_in
      @reader.archive!
      assert @reader.reload.alumni?
      before = @reader.participation.attributes
      sign_in_as(@site_admin)

      change_role(@reader, 'admin')
      assert_response :see_other
      assert @reader.reload.admin?
      assert @reader.alumni?
      assert_equal before, @reader.participation.reload.attributes

      browser = open_session
      sign_in_as(@reader, browser: browser)
      browser.get "#{mount}/admin"
      browser.assert_response :success
      assert @reader.reload.alumni?
      assert_equal before, @reader.participation.reload.attributes

      change_role(@reader, 'reader')
      assert_response :see_other
      browser.get "#{mount}/admin"
      browser.assert_response :not_found
      browser.get "#{mount}/profile"
      browser.assert_response :success
      assert @reader.reload.alumni?
      assert_equal before, @reader.participation.reload.attributes
    end

    def test_an_alumni_site_admin_can_still_manage_roles
      @site_admin.archive!
      sign_in_as(@site_admin)

      change_role(@reader, 'admin')

      assert_response :see_other
      assert @reader.reload.admin?
      assert @site_admin.reload.alumni?
    end

  private

    def mount = Bible270.config.mount_at.chomp('/')
    def role_path(reader) = "#{mount}/admin/readers/#{reader.id}/role"
    def reader_path(reader) = "#{mount}/admin/readers/#{reader.id}"

    def create_reader(name, admin: false)
      email = "role-#{name}@example.org"
      Bible270::Reader.create!(provider: 'email', uid: email, email: email,
                               display_name: name, admin: admin)
    end

    def sign_in_as(reader, browser: self)
      _record, raw = Bible270::SignInToken.issue!(reader.email)
      browser.get "#{mount}/sign_in/email/#{raw}"
      browser.assert_response :redirect
    end

    def change_role(reader, role)
      patch role_path(reader), params: role.nil? ? {} : { role: role }
    end

    def assert_role_requests_hidden
      before = Bible270::Reader.order(:id).pluck(:id, :admin, :email)
      [@reader, @admin, @site_admin].each do |target|
        %w[admin reader].each do |role|
          patch role_path(target), params: { role: role, view: 'admin', site_admin: true, admin: true }
          assert_response :not_found
        end
      end
      assert_equal before, Bible270::Reader.order(:id).pluck(:id, :admin, :email)
    end

    def with_forgery_protection
      previous = ActionController::Base.allow_forgery_protection
      ActionController::Base.allow_forgery_protection = true
      yield
    ensure
      ActionController::Base.allow_forgery_protection = previous
    end

    def csrf_token
      get "#{mount}/session/refresh"
      assert_response :no_content
      token = response.headers['X-CSRF-Token']
      assert token.present?
      token
    end
  end
end
