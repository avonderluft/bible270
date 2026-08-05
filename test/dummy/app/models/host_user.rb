# frozen_string_literal: true

# A stand-in for a host application's own user model, so Reader.for_owner — the
# bridge a host uses when it already has accounts — can be exercised for real.
# A polymorphic owner cannot be faked with a Struct.
class HostUser < ActiveRecord::Base
end
