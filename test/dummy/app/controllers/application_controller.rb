# frozen_string_literal: true

# The engine's controllers inherit from this when config.parent_controller is
# left at its default, so the dummy needs one just as a host app does.
class ApplicationController < ActionController::Base
end
