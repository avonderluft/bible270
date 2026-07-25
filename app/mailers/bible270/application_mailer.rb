# frozen_string_literal: true
module Bible270
  class ApplicationMailer < ActionMailer::Base
    default from: -> { Bible270.config.mailer_from }
    layout nil
  end
end
