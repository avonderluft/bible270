# frozen_string_literal: true

Bible270::Engine.routes.draw do
  root to: 'days#index'

  get 'day/:day', to: 'days#show', as: :day, constraints: { day: %r{\d+} }

  # :part is the chapter within the reading; omitted means the first.
  post   'day/:day/toggle/:track/:part', to: 'checkoffs#toggle', as: :toggle_checkoff_part,
                                         constraints: { day: %r{\d+}, part: %r{\d+} }
  post   'day/:day/toggle/:track', to: 'checkoffs#toggle', as: :toggle_checkoff,
                                   constraints: { day: %r{\d+} }
  post   'day/:day/comments',      to: 'comments#create',  as: :day_comments,
                                   constraints: { day: %r{\d+} }
  post   'comments/:id/like',      to: 'likes#toggle',     as: :like_comment
  patch  'comments/:id',           to: 'comments#update'
  delete 'comments/:id',           to: 'comments#destroy', as: :comment

  # Admin panel — 404s unless config.admin_emails / admin_resolver allows you.
  get    'admin',                        to: 'admin#index',            as: :admin
  get    'admin/readers/:id',            to: 'admin#show',             as: :admin_reader
  delete 'admin/readers/:id',            to: 'admin#destroy'
  patch  'admin/readers/:id/profile',    to: 'admin#update_profile', as: :admin_reader_profile
  patch  'admin/readers/:id/notifications', to: 'admin#update_notifications', as: :admin_reader_notifications
  delete 'admin/readers/:id/avatar',     to: 'admin#remove_avatar', as: :admin_reader_avatar
  patch  'admin/readers/:id/version',    to: 'admin#update_bible_version', as: :admin_reader_version
  patch  'admin/readers/:id/start',      to: 'admin#update_start',     as: :admin_reader_start
  patch  'admin/readers/:id/through',    to: 'admin#complete_through', as: :admin_reader_through
  post   'admin/readers/:id/days/:day',  to: 'admin#toggle_day',       as: :admin_reader_day

  post   'admin/broadcast',              to: 'admin#broadcast',        as: :admin_broadcast
  patch  'admin/enrollment',             to: 'admin#update_enrollment', as: :admin_enrollment
  patch  'admin/run-start',              to: 'admin#update_run_start', as: :admin_run_start
  delete 'admin/run-start',              to: 'admin#reset_run_start'
  get    'admin/comments',               to: 'admin#comments',         as: :admin_comments
  patch  'admin/comments/:id/hide',      to: 'admin#hide_comment',     as: :admin_hide_comment
  patch  'admin/comments/:id/unhide',    to: 'admin#unhide_comment',   as: :admin_unhide_comment
  delete 'admin/comments/:id',           to: 'admin#destroy_comment',  as: :admin_comment

  get   'profile',                       to: 'profiles#edit', as: :profile
  patch 'profile',                       to: 'profiles#update'
  delete 'profile/avatar', to: 'profiles#remove_avatar', as: :profile_avatar

  get 'reflections', to: 'comments#index', as: :reflections

  get 'progress', to: 'readers#progress', as: :progress

  get 'community', to: 'readers#index', as: :community
  get 'mention-suggestions', to: 'readers#mention_suggestions', as: :mention_suggestions, defaults: { format: :json }
  get 'readers/:id', to: 'readers#show', as: :reader

  # Built-in OmniAuth sign-in. The request phase (POST <mount>/auth/:provider)
  # is handled by the OmniAuth middleware in the host app, not by these routes.
  get    'sign_in',                 to: 'sessions#new', as: :sign_in
  get    'session/refresh',         to: 'sessions#refresh', as: :refresh_session

  # Email (magic link) sign-in, for readers without a social account.
  post   'sign_in/email',           to: 'sessions#email_link',     as: :email_sign_in_link
  get    'sign_in/email/:token',    to: 'sessions#email_callback', as: :email_sign_in
  get    'auth/:provider/callback', to: 'sessions#create'
  post   'auth/:provider/callback', to: 'sessions#create'
  get    'auth/failure',            to: 'sessions#failure'
  delete 'sign_out',                to: 'sessions#destroy', as: :sign_out
end
