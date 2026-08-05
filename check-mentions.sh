#!/usr/bin/env bash
# Every file the mentions feature needs. Run from the gem root.
status=0
check() {
  if [ ! -f "$1" ]; then printf '  MISSING   %s\n' "$1"; status=1
  elif ! grep -q "$2" "$1"; then printf '  STALE     %-58s (no %s)\n' "$1" "$2"; status=1
  else printf '  ok        %s\n' "$1"
  fi
}
check lib/bible270/mentions.rb                              'module Mentions'
check lib/bible270.rb                                       "bible270/mentions"
check lib/bible270/configuration.rb                         'mention_notifications'
check db/migrate/20260101000011_add_mention_notices_to_bible270_readers.rb 'notify_on_mention'
check app/models/bible270/reader.rb                          'def mention_handle'
check app/models/bible270/comment.rb                         'def notify_mentioned_readers'
check app/mailers/bible270/notice_mailer.rb                  'def mentioned'
check app/views/bible270/notice_mailer/mentioned.text.erb    'mentioned you'
check app/views/bible270/notice_mailer/mentioned.html.erb    'mentioned you'
check app/helpers/bible270/plan_helper.rb                    'def b270_with_mentions'
check app/controllers/bible270/days_controller.rb            'def reply_prefix'
check app/controllers/bible270/profiles_controller.rb        'notify_on_mention'
check app/views/bible270/comments/_comment.html.erb          'b270_with_mentions'
check app/views/bible270/profiles/edit.html.erb              'notify_on_mention'
check app/views/bible270/shared/_styles.html.erb             'b270-mention'
echo
[ $status -eq 0 ] && echo "All present." || echo "Copy the files marked above, then re-run."
exit $status
