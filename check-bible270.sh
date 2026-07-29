#!/usr/bin/env bash
# Run from the root of your bible270 checkout. Reports which expected symbols are
# present in which files, so a partially-applied update is visible in one pass
# instead of one 500 at a time.

status=0
check() { # file, pattern, label
  if [ ! -f "$1" ]; then printf '  MISSING FILE  %s\n' "$1"; status=1
  elif grep -q "$2" "$1"; then printf '  ok            %s (%s)\n' "$1" "$3"
  else printf '  STALE         %s — no %s\n' "$1" "$3"; status=1
  fi
}

echo "profile / names:"
check lib/bible270/names.rb                          'module Names'          'Names module'
check lib/bible270.rb                                "bible270/names"        'require names'
check app/controllers/bible270/profiles_controller.rb 'class ProfilesController' 'controller'
check app/views/bible270/profiles/edit.html.erb       'first_name'            'edit form'
check config/routes.rb                                "profiles#edit"         'profile route'
check app/models/bible270/reader.rb                   'def suggested_names'   'suggested_names'
check app/models/bible270/reader.rb                   'def update_names'      'update_names'
check app/views/bible270/shared/_header.html.erb      'profile_path'          'Profile nav link'

echo "admin:"
check app/controllers/bible270/admin_controller.rb    'def update_name'       'update_name'
check app/controllers/bible270/admin_controller.rb    'def comments'          'moderation'
check app/views/bible270/admin/show.html.erb          'admin_reader_name_path' 'name form'
check app/views/bible270/admin/comments.html.erb      'admin_hide_comment_path' 'moderation view'
check app/models/bible270/reader.rb                   'def set_start_date!'   'ungated start date'
check app/models/bible270/reader.rb                   'def mark_through!'     'completions'
check app/models/bible270/comment.rb                  'def hide!'             'hide/unhide'
check config/routes.rb                                'admin_reader_name'     'admin name route'

echo "day index on every page:"
check app/views/bible270/shared/_day_index.html.erb   'b270-grid'             'partial'
check app/views/layouts/bible270/application.html.erb 'day_index'             'rendered in layout'
check app/models/bible270/reader.rb                   'def day_status'        'no-N+1 status'
check app/helpers/bible270/plan_helper.rb             'day_status'            'helper uses it'

echo "avatars / nav:"
check lib/bible270/avatars.rb                         'module Avatars'        'Avatars module'
check lib/bible270.rb                                 "bible270/avatars"      'require avatars'
check app/models/bible270/reader.rb                   'def self.avatar_uploads?' 'avatar_uploads?'
check app/models/bible270/reader.rb                   'def attach_avatar'     'attach_avatar'
check app/helpers/bible270/plan_helper.rb             'b270_avatar_src'       'avatar src'
check app/controllers/bible270/profiles_controller.rb 'def remove_avatar'     'remove_avatar'
check config/routes.rb                                'profile_avatar'        'avatar route'
check app/views/bible270/shared/_styles.html.erb      'b270-nav .b270-linkbtn' 'nav alignment'
check lib/bible270/configuration.rb                   'avatar_max_bytes'      'avatar config'

echo "closing a run:"
check app/models/bible270/setting.rb                  'ENROLLMENT_CLOSED_AT'  'Setting model'
check db/migrate/20260101000007_create_bible270_settings.rb 'bible270_settings' 'settings migration'
check app/controllers/bible270/admin_controller.rb    'def update_enrollment'  'admin toggle'
check app/controllers/bible270/sessions_controller.rb 'enrollment_closed?'     'enforcement'
check app/controllers/bible270/application_controller.rb 'enrollment_closed?'  'view helper'
check app/views/bible270/admin/index.html.erb         'admin_enrollment_path'  'admin panel'
check app/views/bible270/sessions/new.html.erb        'enrollment_closed?'     'sign-in banner'
check app/models/bible270/reader.rb                   'email_reader_exists?'   'existence checks'
check config/routes.rb                                'admin_enrollment'       'enrollment route'
check lib/bible270/configuration.rb                   'enrollment_open'        'config flag'

echo "profile extras (avatars, translations):"
check lib/bible270/avatars.rb                         'module Avatars'         'Avatars module'
check lib/bible270/translations.rb                    'module Translations'    'Translations module'
check lib/bible270.rb                                 "bible270/avatars"       'require avatars'
check lib/bible270.rb                                 "bible270/translations"  'require translations'
check lib/bible270/configuration.rb                   'bible_versions'         'bible_versions'
check lib/bible270/configuration.rb                   'gateway_code'           'gateway mapping in url builder'
check db/migrate/20260101000008_add_bible_version_to_bible270_readers.rb 'bible_version' 'translation migration'
check app/models/bible270/reader.rb                   'effective_bible_version' 'reader preference'
check app/helpers/bible270/plan_helper.rb              'b270_version_tag'       'version tag helper'
check app/controllers/bible270/profiles_controller.rb  'update_bible_version'   'profile accepts it'
check app/views/bible270/profiles/edit.html.erb        'bible_version'          'translation select'
check app/views/bible270/days/_reading.html.erb        'b270_version_tag'       'tag after each reading'
check app/views/bible270/shared/_styles.html.erb       'b270-version'           'version styling'
check app/views/layouts/bible270/application.html.erb  'hide_day_index'         'day-index opt-out'
check app/views/bible270/readers/show.html.erb         'hide_day_index'         'progress page opts out'
check app/views/bible270/admin/show.html.erb           'hide_day_index'         'admin page opts out'

echo
[ $status -eq 0 ] && echo "All present." || echo "Some files are stale or missing (see above)."
exit $status
