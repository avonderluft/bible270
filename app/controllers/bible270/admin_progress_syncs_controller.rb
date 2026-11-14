# frozen_string_literal: true

require 'bible270/progress_sync'
require 'bible270/progress_sync/client'

module Bible270
  class AdminProgressSyncsController < ApplicationController
    CANDIDATE_SESSION_KEY = :bible270_progress_sync_candidate
    CANDIDATE_PURPOSE = 'progress-sync-link'

    before_action :require_admin!
    before_action :require_admin_view!
    before_action :load_reader

    rescue_from ProgressSync::Error, with: :sync_error
    rescue_from ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique, with: :invalid_link

    # Also used by the partial after the lookup redirect; no Admin#show setup is needed.
    def self.candidate_for(token, reader:, admin:)
      candidate = verifier.verified(token.to_s, purpose: CANDIDATE_PURPOSE)
      return unless candidate.is_a?(Hash) && candidate['remote'].is_a?(Hash)

      context = link_context(reader: reader, admin: admin, destination: candidate['destination'])
      return unless context.all? { |key, value| candidate[key] == value }
      return unless normalized_email(candidate['remote']['email']) == context['email']

      candidate
    rescue ProgressSync::Error
      nil
    end

    def self.verifier
      Rails.application.message_verifier('bible270-progress-sync-link')
    end

    def self.link_context(reader:, admin:, destination:)
      raise ProgressSync::Unavailable, 'Progress sync migration is not installed' unless ProgressSync.available?

      membership = Participation.chosen.active.find_by(reader_id: reader.id)
      raise ProgressSync::Conflict, 'This reader must be active in the current run before linking progress' unless membership

      email = normalized_email(reader.email)
      # Construction validates the allowlist, instance ID, HTTPS URL and secret, without HTTP.
      ProgressSync::Client.new(destination.to_s)
      entry = Bible270.config.progress_sync_destinations.fetch(destination.to_s)
      {
        'reader_id' => reader.id, 'admin_id' => admin.id,
        'participation_id' => membership.id, 'generation' => membership.progress_sync_generation,
        'destination' => destination.to_s, 'destination_url' => (entry[:url] || entry['url']).to_s.chomp('/'),
        'instance_id' => Bible270.config.progress_sync_instance_id.to_s, 'email' => email
      }
    end

    def self.normalized_email(email)
      value = email.to_s.strip.downcase
      unless value.bytesize <= 320 && value.match?(%r{\A[^@\s]+@[^@\s]+\z})
        raise ProgressSync::Conflict, 'This reader needs a valid email address before linking progress'
      end

      value
    end

    def lookup
      session.delete(CANDIDATE_SESSION_KEY)
      context = self.class.link_context(reader: @reader, admin: current_reader, destination: params[:destination])
      remote = ProgressSync.lookup(destination: context['destination'], email: context['email'])
      unless remote.is_a?(Hash) && self.class.normalized_email(remote['email']) == context['email']
        raise ProgressSync::Conflict, 'Destination account email does not match this reader'
      end

      # Keep only the authenticated lookup fields, never destination credentials.
      candidate = context.merge('remote' => remote.slice('reader_id', 'participation_id', 'generation', 'name', 'email', 'plan_fingerprint'))
      session[CANDIDATE_SESSION_KEY] = self.class.verifier.generate(candidate, expires_in: 10.minutes, purpose: CANDIDATE_PURPOSE)
      redirect_to_panel
    end

    def create
      session.delete(CANDIDATE_SESSION_KEY)
      candidate = confirmed_candidate!
      # Match the core's lock order so confirmation and link creation see the same source identity.
      Participation.find(candidate['participation_id']).plan_run.with_lock do
        @reader.with_lock do
          candidate = confirmed_candidate!
          ProgressSync.link!(reader: @reader, destination: candidate['destination'], remote: candidate['remote'],
                             expected_participation_id: candidate['participation_id'])
        end
      end
      redirect_to_panel(notice: 'Account linked. Existing progress is unchanged.')
    end

    def copy
      ensure_available!
      delivery = ProgressSync.copy_existing!(owned_link)
      redirect_to_panel(notice: delivery ? 'Existing progress queued.' : 'There is no existing progress to sync.')
    end

    def destroy
      ensure_available!
      owned_link.destroy!
      redirect_to_panel(notice: 'Account unlinked. All check-offs are unchanged.')
    end

  private

    def load_reader
      @reader = Reader.find(params[:reader_id])
    end

    def ensure_available!
      raise ProgressSync::Unavailable, 'Progress sync migration is not installed' unless ProgressSync.available?
    end

    def confirmed_candidate!
      candidate = self.class.candidate_for(params[:candidate], reader: @reader, admin: current_reader)
      unless candidate && params[:destination].to_s == candidate['destination']
        raise ProgressSync::Conflict, 'Account confirmation expired or changed. Find the account again.'
      end

      candidate
    end

    def owned_link
      ProgressSyncLink.joins(:participation).where(bible270_participations: { reader_id: @reader.id }).find(params[:id])
    end

    def redirect_to_panel(**flash)
      redirect_to admin_reader_path(@reader, anchor: 'b270-progress-sync'), status: :see_other, **flash
    end

    def sync_error(error)
      session.delete(CANDIDATE_SESSION_KEY)
      redirect_to_panel(alert: error.message)
    end

    def invalid_link(_error)
      session.delete(CANDIDATE_SESSION_KEY)
      redirect_to_panel(alert: 'This account could not be linked. It may already be linked.')
    end
  end
end
