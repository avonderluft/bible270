#!/usr/bin/env bash
# Every file the likes feature needs. Run from the gem root.
status=0
check() {
  if [ ! -f "$1" ]; then printf '  MISSING   %s\n' "$1"; status=1
  elif ! grep -q "$2" "$1"; then printf '  STALE     %-56s (no %s)\n' "$1" "$2"; status=1
  else printf '  ok        %s\n' "$1"
  fi
}
check db/migrate/20260101000013_create_bible270_likes.rb  'create_table :bible270_likes'
check app/models/bible270/like.rb                         'class Like'
check app/models/bible270/comment.rb                      'def toggle_like!'
check app/models/bible270/comment.rb                      'HEART'
check app/models/bible270/reader.rb                       'has_many :likes'
check app/controllers/bible270/likes_controller.rb        'def toggle'
check app/controllers/bible270/comments_controller.rb     'likes: :reader'
check app/views/bible270/likes/_likes.html.erb            'b270-heart'
check app/views/bible270/likes/toggle.turbo_stream.erb    'likes-'
check app/views/bible270/comments/_comment.html.erb       'likes/likes'
check app/views/bible270/shared/_styles.html.erb          'b270-likebtn'
check config/routes.rb                                    'like_comment'
echo
[ $status -eq 0 ] && echo "All present." || echo "Copy the files marked above, then re-run."
exit $status
