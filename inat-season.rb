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
  :yaml => nil,
  :months => {
    :first => 1,
    :last => 12
  },
  :source => nil,
  :neighbours => [],
  :file_output => nil,
}

VERSION = '0.9a'
LICENSE = 'GNU General Public License version 3.0 (GPLv3)'
HOMEPAGE = 'http://github.com/shikhalev/inat-season'
AUTHOR  = 'Ivan Shikhalev <shikhalev@gmail.com>'

ABOUT = hi("iNat-Season v#{VERSION}") + ": season statictics and compare lists generator for iNaturalist's projects.\n" +
        "           #{hi('Author')}: #{AUTHOR}\n" +
        "           #{hi('GitHub')}: #{HOMEPAGE}\n" +
        "          #{hi('License')}: #{LICENSE}\n"

USAGE = "#{hi('Usage:')} inat-season.rb [options] [config.yaml]\n" +
        "   #{hi('or:')} ruby [/path/to/]inat-season.rb [options] [config.yaml]\n" +
        "if config file is not specified, defaults to season-config.yaml in current working directory."

opts = OptionParser.new(USAGE) do |o|

  o.separator ''

  o.on '-h', '--help', 'Show short help and exit.' do
    puts ABOUT
    puts ''
    puts opts.help
    exit 0
  end

  o.on '-?', '--usage', 'Show usage info and exit.' do
    puts opts.help
    exit 0
  end

  o.on '--about', 'Show information about program and exit.' do
    puts ABOUT
    exit 0
  end

  o.on '-v', '--version', 'Show version and exit.' do
    puts VERSION
    exit 0
  end

  o.separator ''

  o.on '--first-month', Integer, 'Month from which the period starts [1-12].' do |value|
    CONFIG[:months][:first] = value
  end

  o.on '--last-month', Integer, 'Month which the period ends [1-12].' do |value|
    CONFIG[:months][:last] = value
  end

  o.on '-s', '--source', String, 'CSV-file of main data.' do |value|
    CONFIG[:source] = value
  end

  o.on '-n', '--neighbour', String, 'CSV-file with neighbour data.' do |value|
    CONFIG[:neighbours] << value
  end

  o.on '-N', '--neighbours', Array, 'Comma-separated list of CSV-files with neighbour data.' do |value|
    CONFIG[:neighbours] += value
  end

  o.on '-f', '--file-output',
       "Write output to file(-s) instead of stdout. Output file",
       "has same base name as YAML-config and '.htm' extesion." do
    CONFIG[:file_output] = true
  end

end

rest = opts.parse ARGV

if rest == nil || rest.empty?
  CONFIG[:yaml] = ['./season-config.yaml']
else
  CONFIG[:yaml] = rest
end

pp CONFIG
