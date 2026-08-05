#!/usr/bin/env bash
# Every file threaded replies needs. Run from the gem root.
status=0
check() {
  if [ ! -f "$1" ]; then printf '  MISSING   %s\n' "$1"; status=1
  elif ! grep -q "$2" "$1"; then printf '  STALE     %-56s (no %s)\n' "$1" "$2"; status=1
  else printf '  ok        %s\n' "$1"
  fi
}
check db/migrate/20260101000012_add_parent_to_bible270_comments.rb 'add_reference'
check app/models/bible270/comment.rb                        'has_many :replies'
check app/models/bible270/comment.rb                        'threads_for_day'
check app/controllers/bible270/comments_controller.rb       ':parent_id'
check app/controllers/bible270/days_controller.rb           'def reply_parent'
check app/views/bible270/comments/_comment.html.erb         'b270-replies'
check app/views/bible270/comments/_form.html.erb            'hidden_field :parent_id'
check app/views/bible270/comments/_form.html.erb            'Replying to'
check app/views/bible270/comments/create.turbo_stream.erb   'replies-'
check app/views/bible270/shared/_styles.html.erb            'b270-reply'
check app/views/bible270/admin/comments.html.erb            'reply to'
check app/controllers/bible270/admin_controller.rb          'parent: :reader'
echo
[ $status -eq 0 ] && echo "All present." || echo "Copy the files marked above, then re-run."
exit $status
