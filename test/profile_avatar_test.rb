# frozen_string_literal: true

require_relative 'support/profiles_controller_test_case'

if RAILS_LOADED
  class ProfileAvatarTest < Bible270ProfilesControllerTestCase
    def test_invalid_fields_leave_the_entire_profile_and_existing_avatar_untouched
      prepare_profile_with_avatar
      invalid_fields = [
        { first_name: " \u00A0 " }, { last_name: '' }, { bible_version: 'unknown' },
        { passage_source: 'unknown' }, { display_mode: 'sepia' },
        { comment_notifications: 'unknown' }, { daily_reminder_minute: '99' },
        { daily_reminder_hour: '', daily_reminder_minute: '' }
      ]

      invalid_fields.each do |invalid|
        with_uploaded_avatar do |upload|
          assert_profile_unchanged do
            patch "#{mount}/profile", params: complete_profile_params.merge(avatar: upload).merge(invalid)
          end
        end
        assert_response :unprocessable_entity
        assert_select '.b270-flash.alert', text: %r{Please give}
      end
    end

    def test_invalid_avatar_leaves_all_settings_and_existing_avatar_untouched
      prepare_profile_with_avatar
      [{ content_type: 'image/svg+xml' }, { contents: '' },
       { contents: 'x' * (Bible270::Avatars.max_bytes + 1) }].each do |options|
        with_uploaded_avatar(**options) do |upload|
          assert_profile_unchanged do
            patch "#{mount}/profile", params: complete_profile_params.merge(avatar: upload)
          end
        end
        assert_response :unprocessable_entity
      end
    end

    def test_a_valid_profile_saves_every_setting_and_replaces_the_avatar
      prepare_profile_with_avatar(optimized: true)
      previous_blob_id = @reader.avatar.blob.id
      previous_thumbnail_id = @reader.avatar_thumbnail.blob.id
      with_uploaded_avatar do |upload|
        patch "#{mount}/profile", params: complete_profile_params.merge(avatar: upload)
      end

      assert_response :redirect
      assert_equal 'Your profile has been updated.', flash[:notice]
      @reader.reload
      assert_equal 'New First', @reader.first_name
      assert_equal 'von Last', @reader.last_name
      assert_equal 'New First von Last', @reader.display_name
      assert_equal 'LSB', @reader.bible_version
      assert_equal 'blue_letter_bible', @reader.passage_source
      assert_equal 'dark_green', @reader.display_mode
      assert_equal 'personal', @reader.comment_notification_level
      assert @reader.notify_on_mention
      refute @reader.notify_on_all_comments
      assert @reader.daily_reminders
      assert_equal '06:45', @reader.daily_reminder_time
      refute_equal previous_blob_id, @reader.avatar.blob.id
      assert_equal avatar_png, @reader.avatar.download
      assert_equal 'replacement.png', @reader.avatar.filename.to_s
      assert_equal 'image/png', @reader.avatar.content_type
      assert @reader.avatar_optimized?
      refute_equal previous_thumbnail_id, @reader.avatar_thumbnail.blob.id
      thumbnail = Vips::Image.new_from_buffer(@reader.avatar_thumbnail.download, '')
      assert_equal [256, 256], [thumbnail.width, thumbnail.height]
      assert_equal 'webpload_buffer', thumbnail.get('vips-loader')
      assert_equal 0, thumbnail.get_typeof('n-pages')
      assert_equal 'image/webp', @reader.avatar_thumbnail.content_type
      follow_redirect!
      assert_select '.b270-avatarrow img' do |images|
        assert_equal Rails.application.routes.url_helpers.rails_blob_path(@reader.avatar_thumbnail, only_path: true), images.first['src']
      end
    end

    def test_model_validation_failure_rerenders_without_saving_or_uploading
      prepare_profile_with_avatar
      other = Bible270::Reader.create!(provider: 'email', uid: 'other@example.org', display_name: 'Other')
      resolver = ->(_controller) { @reader }

      Bible270.config.stub(:current_reader_resolver, -> { resolver }) do
        with_uploaded_avatar do |upload|
          assert_profile_unchanged do
            # Exercise a real AR validation failure after the form checks pass.
            @reader.uid = other.uid
            patch "#{mount}/profile", params: complete_profile_params.merge(avatar: upload)
          end
        end
      end

      assert_response :unprocessable_entity
      assert_select '.b270-flash.alert', text: %r{Your profile could not be saved.*Uid has already been taken}
      assert_empty @reader.attachment_changes
      assert_select 'input[name="first_name"][value="  New   First  "]'
      assert_select 'select[name="display_mode"] option[value="dark_green"][selected]'
      assert_select 'select[name="daily_reminder_hour"] option[value="06"][selected]'
      assert_select '.b270-avatarrow img[src*="original.png"]'
    end

    def test_malformed_avatar_bytes_preserve_every_setting_and_both_images
      prepare_profile_with_avatar(optimized: true)
      with_uploaded_avatar(contents: 'not a PNG') do |upload|
        assert_profile_unchanged do
          patch "#{mount}/profile", params: complete_profile_params.merge(avatar: upload)
        end
      end

      assert_response :unprocessable_entity
      assert_select '.b270-flash.alert', text: %r{Avatar.*decode}
    end

    def test_processor_failure_preserves_every_setting_and_both_images
      prepare_profile_with_avatar(optimized: true)
      failure = ->(*) { raise Bible270::AvatarOptimizer::Error, 'Avatar processing is unavailable.' }
      Bible270::AvatarOptimizer.stub(:open, failure) do
        with_uploaded_avatar do |upload|
          assert_profile_unchanged do
            patch "#{mount}/profile", params: complete_profile_params.merge(avatar: upload)
          end
        end
      end

      assert_response :unprocessable_entity
      assert_select '.b270-flash.alert', text: 'Avatar processing is unavailable.'
    end

    def test_storage_failure_preserves_every_setting_and_both_images
      prepare_profile_with_avatar(optimized: true)
      failure = ->(*) { raise IOError, 'storage unavailable' }
      ActiveStorage::Blob.service.stub(:upload, failure) do
        with_uploaded_avatar do |upload|
          assert_profile_unchanged(allow_storage_writes: true) do
            patch "#{mount}/profile", params: complete_profile_params.merge(avatar: upload)
          end
        end
      end

      assert_response :unprocessable_entity
      assert_select '.b270-flash.alert', text: %r{picture could not be stored}
    end

    def test_upload_without_active_storage_is_rejected_without_saving_settings
      sign_in_as(@reader)
      attributes = @reader.reload.attributes
      Bible270::Reader.stub(:avatar_uploads?, false) do
        with_uploaded_avatar do |upload|
          patch "#{mount}/profile", params: complete_profile_params.merge(avatar: upload)
        end
      end

      assert_response :unprocessable_entity
      assert_select '.b270-flash.alert', text: %r{valid image}
      assert_equal attributes, @reader.reload.attributes
    end

    def test_omitting_translation_and_avatar_preserves_them
      prepare_profile_with_avatar
      blob_id = @reader.avatar.blob.id
      patch "#{mount}/profile", params: complete_profile_params.except(:bible_version)

      assert_response :redirect
      assert_equal 'KJV', @reader.reload.bible_version
      assert_equal blob_id, @reader.avatar.blob.id
    end

    def test_remove_picture_is_beside_upload_controls_and_targets_a_separate_form
      skip 'Active Storage unavailable' unless Bible270::Reader.avatar_uploads?

      @reader.avatar.attach(io: StringIO.new('x'), filename: 'a.png', content_type: 'image/png')
      sign_in_as(@reader)
      get "#{mount}/profile"

      assert_select '.b270-avatarrow .b270-avatarcontrols' do
        assert_select 'input[type="file"][name="avatar"]'
        assert_select 'button[type="submit"][form="b270-remove-picture"]', text: 'Remove picture'
      end
      assert_select 'label button', count: 0
      assert_select 'form form', count: 0
      assert_select '.b270-panel > form#b270-remove-picture[hidden][method="post"]' \
                    '[data-turbo-confirm="Remove your picture?"]' do |forms|
        assert_equal "#{mount}/profile/avatar", forms.first['action']
        assert_select 'input[name="_method"][value="delete"]'
        assert_select 'input[name="first_name"], input[name="last_name"], input[name="avatar"]', count: 0
      end
    end

    def test_remove_picture_is_hidden_without_an_uploaded_avatar
      sign_in_as(@reader)
      get "#{mount}/profile"

      assert_select 'button[form="b270-remove-picture"]', count: 0
      assert_select 'form#b270-remove-picture', count: 0
    end

    def test_a_picture_can_be_removed
      skip 'Active Storage unavailable' unless Bible270::Reader.avatar_uploads?

      prepare_profile_with_avatar(optimized: true)
      assert @reader.reload.avatar_uploaded?
      assert @reader.avatar_thumbnail.attached?

      delete "#{mount}/profile/avatar"

      assert_response :redirect
      refute @reader.reload.avatar_uploaded?
      refute @reader.avatar_thumbnail.attached?
    end

    def test_a_visitor_cannot_remove_a_picture
      delete "#{mount}/profile/avatar"

      assert_response :redirect
      assert_match(%r{sign_in}, response.location)
    end
  end
end
