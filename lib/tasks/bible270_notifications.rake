# frozen_string_literal: true

namespace :bible270 do
  namespace :notifications do
    desc 'Email every existing reader about each new reflection and reply'
    task enable_all: :environment do
      unless Bible270::Reader.comment_notification_columns?
        abort 'Reflection email columns are missing. Run bin/rails bible270:install:migrations and bin/rails db:migrate.'
      end

      total = Bible270::Reader.count
      puts "Found #{total} Bible270 #{'reader'.pluralize(total)} in the #{Rails.env} environment."
      if total.zero?
        puts 'No reader settings were changed.'
        puts 'Rerun with RAILS_ENV=production if that is where your readers are stored.' unless Rails.env.production?
        next
      end

      readers = Bible270::Reader.where(notify_on_mention: false)
        .or(Bible270::Reader.where(notify_on_all_comments: false))
      updated = 0

      Bible270::Reader.transaction do
        readers.find_each do |reader|
          reader.update_comment_notification_level!('all')
          updated += 1
        end
      end

      if updated.zero?
        puts "All #{total} #{'reader'.pluralize(total)} already receive every new reflection and reply."
      else
        puts "Updated #{updated} #{'reader'.pluralize(updated)}. " \
             "All #{total} #{'reader'.pluralize(total)} now receive every new reflection and reply."
      end
    end
  end
end
