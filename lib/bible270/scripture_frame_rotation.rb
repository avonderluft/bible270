# frozen_string_literal: true

require 'digest'
require 'json'
require 'securerandom'

module Bible270
  class ScriptureFrameRotation
    SESSION_KEY = 'bible270_scripture_frame_rotation'
    COLUMN = 'scripture_frame_rotation'
    HEX_DIGEST = %r{\A[0-9a-f]{64}\z}
    SEED = %r{\A[0-9a-f]{16}\z}
    private_constant :COLUMN, :HEX_DIGEST, :SEED

    def self.select(pool, reader: nil, session: nil, exclude: nil)
      rotation = new(pool, exclude: exclude)
      if reader&.persisted? && Reader.column_names.include?(COLUMN)
        # Never lock the request's reader: it may carry unsaved profile changes.
        locked = Reader.find(reader.id)
        locked.with_lock do
          frame, state = rotation.advance(locked[COLUMN])
          locked.update_column(COLUMN, state) unless locked[COLUMN] == state
          frame
        end
      else
        rotation.select_from_session(session, reader)
      end
    end

    def initialize(pool, exclude: nil)
      @pool = pool.sort_by(&:id)
      @catalog = Digest::SHA256.hexdigest(JSON.generate(@pool.map(&:id)))
      @exclude = exclude if exclude.is_a?(String)
    end

    def select_from_session(session, reader)
      return @pool.reject { |frame| @pool.length > 1 && frame.id == @exclude }.sample unless session

      identity = reader&.id ? "reader:#{reader.id}" : 'visitor'
      entry = session[SESSION_KEY]
      previous = entry['state'] if entry.is_a?(Hash) && entry['identity'] == identity
      frame, state = advance(previous)
      session[SESSION_KEY] = { 'identity' => identity, 'state' => state }
      frame
    end

    def advance(previous)
      return [nil, {}] if @pool.empty? && !last_digest(previous)

      state = valid_state?(previous) ? previous.dup : fresh_state(last_digest(previous))
      state['deferred'] = state['deferred'].dup
      return [nil, state] if @pool.empty?

      state = fresh_state(state['last']) if state['cursor'] == @pool.length && state['deferred'].empty?
      order = @pool.shuffle(random: Random.new(state['seed'].to_i(16)))
      position = next_position(order, state)
      frame = order[position]
      state['deferred'].delete(position)
      state['last'] = Digest::SHA256.hexdigest(frame.id)
      [frame, state]
    end

  private

    def fresh_state(last)
      { 'version' => 1, 'catalog' => @catalog, 'seed' => SecureRandom.hex(8),
        'cursor' => 0, 'deferred' => [], 'last' => last }
    end

    def last_digest(state)
      state['last'] if state.is_a?(Hash) && state['last'].is_a?(String) && HEX_DIGEST.match?(state['last'])
    end

    def valid_state?(state)
      return false unless state.is_a?(Hash) && state.size == 6 && (state.keys - %w[catalog cursor deferred last seed version]).empty?
      return false unless state['version'] == 1 && state['catalog'] == @catalog
      return false unless state['seed'].is_a?(String) && SEED.match?(state['seed'])
      return false unless state['last'].nil? || last_digest(state)

      valid_positions?(state['cursor'], state['deferred'])
    end

    def valid_positions?(cursor, deferred)
      cursor.is_a?(Integer) && cursor.between?(0, @pool.length) &&
        deferred.is_a?(Array) && deferred.length <= 2 && deferred.uniq == deferred &&
        deferred.all? { |position| position.is_a?(Integer) && position >= 0 && position < cursor }
    end

    # At most two positions can be blocked (last and exclude). Keep them unseen
    # rather than dropping them, including when the next request changes exclude.
    def next_position(order, state)
      position = state['deferred'].find { |index| penalty(order[index], state).zero? }
      return position if position

      while state['cursor'] < order.length
        position = state['cursor']
        state['cursor'] += 1
        return position if penalty(order[position], state).zero?

        state['deferred'] << position
      end
      state['deferred'].min_by { |index| penalty(order[index], state) }
    end

    def penalty(frame, state)
      (Digest::SHA256.hexdigest(frame.id) == state['last'] ? 2 : 0) + (frame.id == @exclude ? 1 : 0)
    end
  end
end
