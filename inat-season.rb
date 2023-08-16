#!/usr/bin/env ruby

require 'pp'
require 'yaml'
require 'csv'
require 'optparse'

def hi str
  if $stdout.stat.chardev?
    "\e[1m#{str}\e[0m"
  else
    str
  end
end

CONFIG = {
  :yaml => :default,
  :period => {
    :begin => 1,
    :end => 12
  },
  :source => nil,
  :neighbours => []
}

USAGE = "#{hi('Usage:')} inat-season.rb [options] [config.yaml]\n" +
        "   #{hi('or:')} ruby [/path/to/]inat-season.rb [options] [config.yaml]\n"

opts = OptionParser.new(USAGE) do |o|

  o.separator ''

  o.on '-?', '--usage', 'Show usage info and exit.' do
    puts opts.help
    exit 0
  end

end

rest = opts.parse ARGV

pp CONFIG
