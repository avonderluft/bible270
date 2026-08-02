# frozen_string_literal: true

Rails.application.routes.draw do
  mount Bible270::Engine, at: Bible270.config.mount_at

  root to: proc { [200, { 'Content-Type' => 'text/plain' }, ['dummy']] }
end
