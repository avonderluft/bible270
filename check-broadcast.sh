#!/usr/bin/env bash
# Every file the broadcast feature needs. Run from the gem root.
status=0
check() {
  if [ ! -f "$1" ]; then printf '  MISSING   %s\n' "$1"; status=1
  elif ! grep -q "$2" "$1"; then printf '  STALE     %-56s (no %s)\n' "$1" "$2"; status=1
  else printf '  ok        %s\n' "$1"
  fi
}
check config/routes.rb                                   'admin_broadcast'
check app/controllers/bible270/admin_controller.rb       'def broadcast'
check app/controllers/bible270/admin_controller.rb       'def deliver_broadcast'
check app/mailers/bible270/notice_mailer.rb              'def broadcast'
check app/views/bible270/notice_mailer/broadcast.text.erb  'app_name'
check app/views/bible270/notice_mailer/broadcast.html.erb  'simple_format'
check app/views/bible270/admin/index.html.erb            'Write to everyone'
check app/views/bible270/shared/_styles.html.erb         'b270-input'
echo
[ $status -eq 0 ] && echo "All present." || echo "Copy the files marked above, then re-run."
exit $status
