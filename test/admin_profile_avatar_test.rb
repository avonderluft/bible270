# frozen_string_literal: true

require_relative 'support/admin_controller_test_case'

if RAILS_LOADED
  class AdminProfileAvatarTest < Bible270AdminControllerTestCase
    def test_admin_name_fields_share_a_short_two_column_row
      sign_in_as_admin
      get "#{mount}/admin/readers/#{@reader.id}"

      assert_select "form[action='#{mount}/admin/readers/#{@reader.id}/profile'][enctype='multipart/form-data']" do
        assert_select '.b270-name-fields' do
          assert_select 'label.b270-field', count: 2
          assert_select 'label.b270-field > span', text: 'First name'
          assert_select 'label.b270-field > input[name="first_name"][size="16"][value="R"]'
          assert_select 'label.b270-field > span', text: 'Last name'
          assert_select 'label.b270-field > input[name="last_name"][size="16"][value="Reader"]'
        end
        assert_select 'input[type="submit"][value="Save"]'
      end
    end

    def test_short_avatar_hints_keep_configured_limits_on_admin_and_profile
      previous = Bible270.config.avatar_max_bytes
      skip 'Active Storage unavailable' unless Bible270::Reader.avatar_uploads?

      Bible270.config.avatar_max_bytes = 3 * 1024 * 1024
      sign_in_as_admin
      ["#{mount}/admin/readers/#{@reader.id}", "#{mount}/profile"].each do |path|
        get path

        assert_response :success
        assert_select '.b270-avatar-hint', count: 1 do |hints|
          assert_equal 'PNG/JPEG/GIF/WebP · max 3MB, 40MP. Center-cropped square; animations use first frame.', hints.first.text.squish
        end
      end
    ensure
      Bible270.config.avatar_max_bytes = previous
    end

    def test_admin_picture_removal_is_next_to_upload_controls_with_a_separate_form
      skip 'Active Storage unavailable' unless Bible270::Reader.avatar_uploads?

      sign_in_as_admin
      get "#{mount}/admin/readers/#{@reader.id}"
      assert_select 'button[form="b270-remove-picture"]', count: 0
      assert_select 'form#b270-remove-picture', count: 0

      @reader.avatar.attach(io: StringIO.new('avatar'), filename: 'avatar.png', content_type: 'image/png')
      get "#{mount}/admin/readers/#{@reader.id}"
      assert_select '.b270-avatarrow .b270-avatarcontrols' do
        assert_select 'input[type="file"][name="avatar"]'
        assert_select 'button[type="submit"][form="b270-remove-picture"]', text: 'Remove picture'
      end
      assert_select 'form form, label button', count: 0
      assert_select '.b270-panel > form#b270-remove-picture[hidden][method="post"]' do |forms|
        assert_equal "#{mount}/admin/readers/#{@reader.id}/avatar", forms.first['action']
        assert_equal "Remove #{@reader.display_name}'s picture?", forms.first['data-turbo-confirm']
        assert_select 'input[name="_method"][value="delete"]'
        assert_select 'input[name="first_name"], input[name="last_name"], input[name="avatar"]', count: 0
      end
    end

    def test_an_admin_can_rename_a_reader
      sign_in_as_admin
      patch "#{mount}/admin/readers/#{@reader.id}/profile",
            params: { first_name: 'Renamed', last_name: 'Person' }

      assert_equal 'Renamed Person', @reader.reload.display_name
    end

    def test_a_half_name_is_rejected_without_changing_the_reader
      original_names = @reader.attributes.slice('first_name', 'last_name', 'display_name')
      sign_in_as_admin

      patch "#{mount}/admin/readers/#{@reader.id}/profile",
            params: { first_name: 'Only', last_name: '' }

      assert_response :redirect
      assert_equal original_names, @reader.reload.attributes.slice('first_name', 'last_name', 'display_name')
      assert_match(%r{first and last name}, flash[:alert].to_s)
    end

    def test_an_invalid_avatar_does_not_partially_update_the_name
      skip 'Active Storage unavailable' unless Bible270::Reader.avatar_uploads?

      original_names = @reader.attributes.slice('first_name', 'last_name', 'display_name')
      sign_in_as_admin

      with_uploaded_avatar(content_type: 'image/svg+xml') do |avatar|
        patch "#{mount}/admin/readers/#{@reader.id}/profile",
              params: { first_name: 'Changed', last_name: 'Name', avatar: avatar }
      end

      assert_response :redirect
      assert_equal original_names, @reader.reload.attributes.slice('first_name', 'last_name', 'display_name')
      refute @reader.avatar_uploaded?
      assert_match(%r{PNG, JPEG, GIF or WebP}, flash[:alert].to_s)
    end

    def test_an_admin_can_upload_and_remove_a_readers_avatar
      skip 'Active Storage unavailable' unless Bible270::Reader.avatar_uploads?

      sign_in_as_admin
      with_uploaded_avatar do |avatar|
        patch "#{mount}/admin/readers/#{@reader.id}/profile", params: { avatar: avatar }
      end

      assert_response :redirect
      assert_equal 'Updated.', flash[:notice]
      assert @reader.reload.avatar_uploaded?
      assert_equal avatar_png, @reader.avatar.download
      assert_equal 'avatar.png', @reader.avatar.filename.to_s
      assert_equal 'image/png', @reader.avatar.content_type
      assert @reader.avatar_optimized?
      thumbnail = Vips::Image.new_from_buffer(@reader.avatar_thumbnail.download, '')
      assert_equal [256, 256], [thumbnail.width, thumbnail.height]
      assert_equal 'webpload_buffer', thumbnail.get('vips-loader')
      assert_equal 0, thumbnail.get_typeof('n-pages')
      assert_equal 'image/webp', @reader.avatar_thumbnail.content_type
      follow_redirect!
      thumbnail_path = Rails.application.routes.url_helpers.rails_blob_path(@reader.avatar_thumbnail, only_path: true)
      assert_select 'img' do |images|
        assert_includes images.map { |image| image['src'] }, thumbnail_path
      end

      delete "#{mount}/admin/readers/#{@reader.id}/avatar"

      assert_response :redirect
      refute @reader.reload.avatar_uploaded?
      refute @reader.avatar_thumbnail.attached?
    end

    def test_admin_replaces_both_images_and_saves_the_name
      prepare_admin_avatar
      previous_ids = [@reader.avatar.blob.id, @reader.avatar_thumbnail.blob.id]
      replacement = Vips::Image.black(320, 480).new_from_image([210, 120, 35]).write_to_buffer('.png')
      with_uploaded_avatar(contents: replacement) do |upload|
        patch "#{mount}/admin/readers/#{@reader.id}/profile",
              params: { first_name: 'Changed', last_name: 'Name', avatar: upload }
      end

      assert_response :redirect
      assert_equal 'Updated.', flash[:notice]
      assert_equal 'Changed Name', @reader.reload.display_name
      assert_equal replacement, @reader.avatar.download
      assert @reader.avatar_optimized?
      refute_equal previous_ids.first, @reader.avatar.blob.id
      refute_equal previous_ids.last, @reader.avatar_thumbnail.blob.id
    end

    def test_admin_malformed_upload_preserves_all_attributes_and_both_images
      prepare_admin_avatar
      with_uploaded_avatar(contents: 'not a PNG') do |upload|
        assert_admin_avatar_unchanged do
          patch "#{mount}/admin/readers/#{@reader.id}/profile",
                params: { first_name: 'Changed', last_name: 'Name', avatar: upload }
        end
      end

      assert_response :redirect
      assert_match(%r{Avatar.*decode}, flash[:alert])
    end

    def test_admin_processor_failure_preserves_all_attributes_and_both_images
      prepare_admin_avatar
      failure = ->(*) { raise Bible270::AvatarOptimizer::Error, 'Avatar processing is unavailable.' }
      Bible270::AvatarOptimizer.stub(:open, failure) do
        with_uploaded_avatar do |upload|
          assert_admin_avatar_unchanged do
            patch "#{mount}/admin/readers/#{@reader.id}/profile",
                  params: { first_name: 'Changed', last_name: 'Name', avatar: upload }
          end
        end
      end

      assert_response :redirect
      assert_equal 'Avatar processing is unavailable.', flash[:alert]
    end

    def test_admin_storage_failure_preserves_all_attributes_and_both_images
      prepare_admin_avatar
      failure = ->(*) { raise IOError, 'storage unavailable' }
      ActiveStorage::Blob.service.stub(:upload, failure) do
        with_uploaded_avatar do |upload|
          assert_admin_avatar_unchanged(allow_storage_writes: true) do
            patch "#{mount}/admin/readers/#{@reader.id}/profile",
                  params: { first_name: 'Changed', last_name: 'Name', avatar: upload }
          end
        end
      end

      assert_response :redirect
      assert_match(%r{picture could not be stored}, flash[:alert])
    end

    def test_admin_model_validation_failure_does_not_write_to_storage
      prepare_admin_avatar
      # The controller loads a fresh reader; invalidate it after form normalization
      # while still exercising the service's real AR validation path.
      invalid_names = { first_name: 'Changed', last_name: 'Name', display_name: '' }
      Bible270::Names.stub(:normalize, invalid_names) do
        with_uploaded_avatar do |upload|
          assert_admin_avatar_unchanged do
            patch "#{mount}/admin/readers/#{@reader.id}/profile",
                  params: { first_name: 'Changed', last_name: 'Name', avatar: upload }
          end
        end
      end

      assert_response :redirect
      assert_match(%r{profile could not be saved}, flash[:alert])
    end

    def test_admin_upload_without_active_storage_does_not_change_attributes
      sign_in_as_admin
      attributes = @reader.reload.attributes
      Bible270::Reader.stub(:avatar_uploads?, false) do
        with_uploaded_avatar do |upload|
          patch "#{mount}/admin/readers/#{@reader.id}/profile",
                params: { first_name: 'Changed', last_name: 'Name', avatar: upload }
        end
      end

      assert_response :redirect
      assert_match(%r{Picture uploads require Active Storage}, flash[:alert])
      assert_equal attributes, @reader.reload.attributes
    end
  end
end
