#!/usr/bin/env bash
# Every file editable reflections needs. Run from the gem root.
status=0
check() {
  if [ ! -f "$1" ]; then printf '  MISSING   %s\n' "$1"; status=1
  elif ! grep -q "$2" "$1"; then printf '  STALE     %-56s (no %s)\n' "$1" "$2"; status=1
  else printf '  ok        %s\n' "$1"
  fi
}
check config/routes.rb                                      "patch  'comments/:id'"
check app/controllers/bible270/comments_controller.rb       'def update'
check app/controllers/bible270/comments_controller.rb       'def own_comment'
check app/models/bible270/comment.rb                        'def edited?'
check app/models/bible270/comment.rb                        'notify_newly_mentioned_readers'
check app/views/bible270/comments/_comment.html.erb         'edit: comment.id'
check app/views/bible270/comments/_edit_form.html.erb       'b270-editing'
check app/views/bible270/comments/_edit_fields.html.erb     'b270-editform'
check app/views/bible270/days/show.html.erb                 'comments/comment'
check app/controllers/bible270/days_controller.rb           'def editing_comment_id'
check app/views/bible270/comments/update.turbo_stream.erb   'comments/comment'
check app/views/bible270/shared/_styles.html.erb            'b270-cedit'
echo
[ $status -eq 0 ] && echo "All present." || echo "Copy the files marked above, then re-run."
exit $status
