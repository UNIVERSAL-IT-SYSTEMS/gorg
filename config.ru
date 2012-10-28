require 'gorg/base'
require 'gorg/application'

# TODO: refactor Gorg init and config code to avoid a nasty class
# construction like this.
class Fake
  extend Gorg
  gorgInit
end

map '/images' do
  mounts = $Config['mounts']
  mount_options = Hash[*mounts.flatten]
  run Rack::File.new(mount_options['/images'])
end

run Gorg::Application.new
