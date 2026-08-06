#!/usr/bin/env bash
# Every file the Reflections page needs. Run from the gem root.
status=0
check() {
  if [ ! -f "$1" ]; then printf '  MISSING   %s\n' "$1"; status=1
  elif ! grep -q "$2" "$1"; then printf '  STALE     %-56s (no %s)\n' "$1" "$2"; status=1
  else printf '  ok        %s\n' "$1"
  fi
}
check config/routes.rb                                 "as: :reflections"
check lib/bible270/configuration.rb                    'reflections_page_size'
check app/controllers/bible270/comments_controller.rb  'def index'
check app/controllers/bible270/comments_controller.rb  'def recent_threads'
check app/views/bible270/comments/index.html.erb       'Days with reflections'
check app/views/bible270/shared/_header.html.erb       'reflections_path'
check app/views/bible270/shared/_styles.html.erb       'b270-threadday'
echo
[ $status -eq 0 ] && echo "All present." || echo "Copy the files marked above, then re-run."
exit $status
