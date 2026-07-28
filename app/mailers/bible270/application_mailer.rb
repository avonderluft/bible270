# frozen_string_literal: true

module Bible270
  class ApplicationMailer < ActionMailer::Base
    default from: -> { Bible270.config.mailer_from }
    # `layout nil` means "normal lookup", which finds the host app's mailer layout and
    # nests our complete HTML document inside theirs. Only `false` disables it.
    layout false
  end
end
