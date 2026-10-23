# frozen_string_literal: true

require 'bible270/avatar_backfill'

namespace :bible270 do
  namespace :avatars do
    desc 'Optimize uploaded reader avatars (DRY_RUN=1, FORCE=1, BATCH_SIZE=100; maximum 1000)'
    task optimize: :environment do
      summary = Bible270::AvatarBackfill.new(
        dry_run: ENV['DRY_RUN'] == '1',
        force: ENV['FORCE'] == '1',
        batch_size: ENV.fetch('BATCH_SIZE', Bible270::AvatarBackfill::DEFAULT_BATCH_SIZE)
      ).run
      if summary[:failed].positive?
        raise Bible270::AvatarBackfill::Error,
              "Avatar backfill failed for #{summary[:failed]} reader(s). Review the reader IDs and failure categories above, correct the problem, and rerun.",
              cause: nil
      end
    end
  end
end
