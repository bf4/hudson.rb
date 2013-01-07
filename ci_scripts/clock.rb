require 'clockwork'
include Clockwork

every(1.hour, 'branch watcher') do
  `ruby /Users/continuum/Sites/hudson_script/branch_watcher.rb > /Users/continuum/branch_log.txt`
end