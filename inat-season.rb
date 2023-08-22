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

def get_yaml name
  path = File.expand_path name
  return path if File.exists? path
  path = File.expand_path "#{name}.yaml"
  return path if File.exists? path
  path = File.expand_path "#{name}.yml"
  return path if File.exists? path
  raise ArgumentError::new "Could not find YAML-file with name '#{name}'"
end

module FromHash
  def load hash, *keys
    keys.each do |key|
      instance_variable_set "@#{key}", hash[key]
    end
  end
end

class Observation

  attr_reader :quality_grade, :observed_on, :scientific_name, :common_name, :taxon_id, :user_login, :url, :id, :iconic_taxon_name
  attr_reader :date
  attr_reader :season

  include FromHash

  def initialize row, config
    @config = config
    load row, :quality_grade, :observed_on, :scientific_name, :common_name, :taxon_id, :user_login, :url, :id, :iconic_taxon_name
    @date = Date::parse @observed_on
    @season = @config[:get_season].call @date
  end

end

class Taxon

  attr_reader :taxon_id, :scientific_name, :common_name, :iconic_taxon_name
  attr_reader :observations

  include FromHash

  def initialize src, config
    @config = config
    @observations = []
    case src
    when Observation
      @taxon_id = src.taxon_id
      @scientific_name = src.scientific_name
      @common_name = src.common_name
      @iconic_taxon_name = src.iconic_taxon_name
      @observations << src
    when Taxon
      @taxon_id = src.taxon_id
      @scientific_name = src.scientific_name
      @common_name = src.common_name
      @iconic_taxon_name = src.iconic_taxon_name
      src.observations.each do |observation|
        @observations << observation
      end
    else
      load src, :taxon_id, :scientific_name, :common_name, :iconic_taxon_name
    end
  end

  def same
    Taxon::new taxon_id: @taxon_id, scientific_name: @scientific_name, common_name: @common_name
  end

  def merge! other
    if @taxon_id != other.taxon_id
      raise ArgumentError::new "Can not merge different taxa: #{@taxon_id} != #{other.taxon_id}"
    end
    @scientific_name ||= other.scientific_name
    @common_name ||= other.common_name
    @observations += other.observations
    @observations.sort_by! { |o| o.date }.uniq!
    self
  end

  def merge other
    result = self.same
    result.merge! self
    result.merge! other
  end

  def clone
    same.merge! self
  end

  def << observation
    @observations << observation
    @observations.sort_by! { |o| o.date }.uniq!
    self
  end

  def each &block
    @observations.each &block
  end

  def observation_count
    @observations.size
  end

end

class List

  def initialize config
    @config = config
    @taxa = {}
  end

  def same
    List::new @config
  end

  def find name
    @taxa.each do |_, v|
      return v if v.scientific_name == name || v.common_name == name
    end
    return nil
  end

  def [] name_or_id
    @taxa ||= {}
    case name_or_id
    when Integer
      @taxa[name_or_id]
    when String
      find name_or_id
    else
      raise ArgumentError::new "Invalid Id class: #{name_or_id.inspect}"
    end
  end

  def each &block
    @taxa ||= {}
    @taxa.to_a.sort_by { |i| i[1].scientific_name }.map { |i| i[1] }.each &block
  end

  def << item
    @taxa ||= {}
    existing = @taxa[item.taxon_id]
    if existing
      case item
      when Taxon
        existing.merge! item
      when Observation
          existing << item
      else
        raise ArgumentError::new "Invalid item class: #{item.class}"
      end
    else
      @taxa[item.taxon_id] = Taxon::new item
    end
  end

  def merge! other
    other.each do |taxon|
      self << taxon
    end
    self
  end

  def clone
    same.merge! self
  end

  def merge other
    result = self.same
    result.merge! self
    result.merge! other
  end

  def taxon_count
    @taxa.size
  end

  def observation_count
    count = 0
    each do |t|
      count += t.observation_count
    end
    count
  end

end

class Season < List

  attr_reader :season

  def initialize season, config
    super config
    @season = season
  end

  def << item
    case item
    when Taxon
      item.each do |observation|
        self << observation
      end
    when Observation
      if item.season == @season
        super item
      end
    end
    self
  end

end

class Seasons

  def initialize config
    @config = config
    @seasons = {}
  end

  def << observation
    season_name = observation.season
    @season[season_name] ||= Season::new @config
    @season[season_name] << observation
  end

end

ICONIC_ORDER = {
  'Aves' => 1,
  'Amphibia' => 2,
  'Reptilia' => 3,
  'Mammalia' => 4,
  'Actinopterygii' => 5,
  'Mollusca' => 6,
  'Arachnida' => 7,
  'Insecta' => 8,
  'Plantae' => 9,
  'Fungi' => 10,
  'Protozoa' => 11,
  'Unknown' => 12,
}

def do_task task, config
  yaml = get_yaml task
  conf = YAML.load_file yaml
  config[:source] = conf['source'] if conf['source']
  config[:search] = conf['search'] if conf['search']
  config[:neighbours] += conf['neighbours'] if conf['neighbours']
  if conf['tops']
    config[:tops][:count] = conf['tops']['count'] if conf['tops']['count']
    config[:tops][:limit] = conf['tops']['limit'] if conf['tops']['limit']
  end

  config[:get_season] = proc do |date|
    date.year.to_s
  end
  if config[:months] && config[:months][:first] && config[:months][:last] && config[:months][:first] > config[:months][:last]
    config[:get_season] = proc do |date|
      if date.month >= config[:months][:first]
        "#{date.year}-#{date.year + 1}"
      else
        "#{date.year - 1}-#{date.year}"
      end
    end
  end

  csv = CSV::table(config[:source])

  data = {}
  need_ids = []

  csv.each do |row|
    row_data = row.to_h.slice :quality_grade, :observed_on, :scientific_name, :common_name, :taxon_id, :user_login, :url, :id, :iconic_taxon_name
    row_data[:iconic_taxon_order] = ICONIC_ORDER[row_data[:iconic_taxon_name]]
    if row_data[:quality_grade] == 'research'
      date = Date::parse row_data[:observed_on]
      row_data[:season] = config[:get_season][date]
      data[row_data[:season]] ||= {}
      data[row_data[:season]][row_data[:scientific_name]] ||= []
      data[row_data[:season]][row_data[:scientific_name]] << row_data
    else
      need_ids << row_data
    end
  end

  sorted = data.to_a.sort_by { |x| x[0] }
  last_season = sorted.last[0]
  stats = []
  last_news = {}
  users_for_top = {}
  users_for_top_last = {}
  sorted.each do |season_row|
    season = season_row[0]
    season_data = season_row[1]
    species = season_data.size
    observations = season_data.to_a.sum { |x| x[1].size }
    new_count = 0
    season_data.each do |scientific_name, obsers|
      obsers.each do |o|
        users_for_top[o[:user_login]] ||= {}
        users_for_top[o[:user_login]][scientific_name] ||= 0
        users_for_top[o[:user_login]][scientific_name] += 1
        if season == last_season
          users_for_top_last[o[:user_login]] ||= {}
          users_for_top_last[o[:user_login]][scientific_name] ||= 0
          users_for_top_last[o[:user_login]][scientific_name] += 1
        end
      end
      flag = true
      data.each do |key, value|
        next if key >= season
        if value.has_key?(scientific_name)
          flag = false
          break
        end
      end
      if flag
        new_count += 1
        if season == last_season
          last_news[scientific_name] = season_data[scientific_name]
        end
      end
    end
    stats << {
      season: season,
      observations: observations,
      species: species,
      news: new_count
    }
  end

  season_query = proc do |s|
    "&d1=#{s}-01-01&d2=#{s}-12-31"
  end
  if config[:months] && config[:months][:first] && config[:months][:last] && config[:months][:first] > config[:months][:last]
    season_query = proc do |s|
      y1 = s[0..3]
      m1 = config[:months][:first].to_s
      m1 = '0' + m1 if m1.length == 1
      d1 = '01'
      y2 = (y1.to_i + 1).to_s
      m2 = config[:months][:last].to_s
      m2 = '0' + m2 if m2.length == 1
      d2 = [
        31,
        28,
        31,
        30,
        31,
        30,
        31,
        31,
        30,
        31,
        30,
        31
      ][config[:months][:last] - 1]
      "&d1=#{y1}-#{m1}-#{d1}&d2=#{y2}-#{m2}-#{d2}"
    end
  end

  html = []
  html << "<h2>Итоги сезона</h2>"
  html << ""
  html << "Здесь и далее учитываются только наблюдения исследовательского уровня, если специально не оговорено иное."
  html << ""
  html << "<h3>История</h3>"
  html << ""
  html << "<table>"
  html << ""
  html << "<tr>"
  html << "<th>Сезон</th>"
  html << "<th>Наблюдения</th>"
  html << "<th>Виды</th>"
  html << "<th>Новые</th>"
  html << "</tr>"
  html << ""

  stats[..-2].each do |row|
    observations_link = config[:search] + '&quality_grade=research' + season_query[row[:season]]
    species_link = observations_link + '&view=species'
    html << "<tr>"
    html << "<td>#{row[:season]}</td>"
    html << "<td><a href=\"#{observations_link}\">#{row[:observations]}</a></td>"
    html << "<td><a href=\"#{species_link}\">#{row[:species]}</a></td>"
    html << "<td>#{row[:news]}</td>"
    html << "</tr>"
    html << ""
  end
  row = stats[-1]
  observations_link = config[:search] + '&quality_grade=research' + season_query[row[:season]]
  species_link = observations_link + '&view=species'
  html << "<tr>"
  html << "<td><b>#{row[:season]}</b></td>"
  html << "<td><a href=\"#{observations_link}\"><b>#{row[:observations]}</b></a></td>"
  html << "<td><a href=\"#{species_link}\"><b>#{row[:species]}</b></a></td>"
  html << "<td><b>#{row[:news]}</b></td>"
  html << "</tr>"
  html << ""

  html << "</table>"

  news_users = {}
  news_user_link = proc do |user|
    num = news_users[user]
    if num == nil
      num = news_users.size + 1
      news_users[user] = num
    end
    "<sup><a href=\"\#news-user-#{num}\">[#{num}]</a></sup>"
  end
  if last_news.size > 0
    sorted_news = last_news.to_a.sort_by { |n| n[0] }.sort_by { |n| n[1][0][:iconic_taxon_order] }
    html << ""
    html << "<h3>Новинки</h3>"
    html << ""
    html << "Виды, в предыдущие сезоны не наблюдавшиеся."
    html << ""
    html << "<table>"
    html << ""
    html << "<tr>"
    html << "<th>Вид</th>"
    html << "<th>Наблюдения</th>"
    html << "</tr>"
    html << ""

    sorted_news.each do |nn|
      scientific_name = nn[0]
      observations = nn[1]
      common_name = observations[0][:common_name]
      taxon_id = observations[0][:taxon_id]
      iconic_class = "icon-iconic-#{observations[0][:iconic_taxon_name].downcase}"
      html << "<tr>"
      html << "<td><a href=\"https://www.inaturalist.org/taxa/#{taxon_id}\"><i class=\"#{iconic_class}\" style=\"font-size: 1.5em\"> </i>#{common_name} <i>(#{scientific_name})</i></a></td>"
      html << "<td>"
      html << observations.map { |o| "<a href=\"#{o[:url]}\">\##{o[:id]}</a>#{news_user_link[o[:user_login]]}" }.join(', ')
      html << "</td>"
      html << "</tr>"
      html << ""
    end

    html << "</table>"
    html << ""
    html << "Новые виды наблюдали:"
    html << "<ul>"
    html << news_users.to_a.sort_by { |u| u[1] }.map { |u| "<li><a name=\"news-user-#{u[1]}\">[#{u[1]}]</a> @#{u[0]}</li>" }.join("\n")
    html << "</ul>"
  end

  top_users = []
  users_for_top.each do |key, value|
    top_users << [key, value.size, value.to_a.sum { |x| x[1] }]
  end
  top_users.filter! { |v| v[1] >= config[:tops][:limit] }
  top_users.sort_by! { |v| v[1] }
  top_users.reverse!
  top_users_last = []
  users_for_top_last.each do |key, value|
    top_users_last << [key, value.size, value.to_a.sum { |x| x[1] }]
  end
  top_users_last.filter! { |v| v[1] >= config[:tops][:limit] }
  top_users_last.sort_by! { |v| v[1] }
  top_users_last.reverse!

  if top_users.size != 0
    html << ""
    html << "<h3>Лучшие наблюдатели</h3>"
    html << ""
    html << "Топ наблюдателей <i>по числу видов</i>. Показаны топ-#{config[:tops][:count]} из тех, у кого число видов не меньше #{config[:tops][:limit]}."
    html << ""
    html << "<h4>За все время</h4>"
    html << ""
    html << "<table>"
    html << ""
    html << "<tr>"
    html << "<th>\#</th><th>Наблюдатель</th><th>Виды</th><th>Наблюдения</th>"
    html << "</tr>"
    html << ""
    top_users[0 .. config[:tops][:count] - 1].each_with_index do |u, i|
      html << "<tr>"
      html << "<td>#{i + 1}</td>"
      html << "<td>@#{u[0]}</td>"
      html << "<td>#{u[1]}</td>"
      html << "<td>#{u[2]}</td>"
      html << "</tr>"
      html << ""
    end
    html << "</table>"

    if top_users_last.size != 0
      html << ""
      html << "<h4>За сезон</h4>"
      html << ""
      html << "<table>"
      html << ""
      html << "<tr>"
      html << "<th>\#</th><th>Наблюдатель</th><th>Виды</th><th>Наблюдения</th>"
      html << "</tr>"
      html << ""
      top_users_last[0 .. config[:tops][:count] - 1].each_with_index do |u, i|
        html << "<tr>"
        html << "<td>#{i + 1}</td>"
        html << "<td>@#{u[0]}</td>"
        html << "<td>#{u[1]}</td>"
        html << "<td>#{u[2]}</td>"
        html << "</tr>"
        html << ""
      end
      html << "</table>"
    end
  end

  #pp last_news

  if config[:file_output]
    filename = File.basename(File.basename(task, '.yml'), '.yaml')
    File::open filename + '.htm', 'w' do |f|
      f.puts html.join("\n")
    end
  else
    $stdout.puts html.join("\n")
  end

  # TODO: this
end

CONFIG = {
  :yaml => nil,
  :months => {
    :first => 1,
    :last => 12
  },
  tops: {
    :count => 10,
    :limit => 10
  },
  :source => nil,
  :search => 'https://www.inaturalist.org/observations?place_id=any',
  :neighbours => [],
  :file_output => nil,
  :no_threads => false,
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

  o.on '-b', '--first-month', Integer, 'Month from which the period starts [1-12].' do |value|
    CONFIG[:months][:first] = value
  end

  o.on '-e', '--last-month', Integer, 'Month which the period ends [1-12].' do |value|
    CONFIG[:months][:last] = value
  end

  o.on '-s', '--source', String, 'CSV-file of main data.' do |value|
    CONFIG[:source] = value
  end

  o.on '-S', '--search', String, 'Base URL for observation search.' do |value|
    CONFIG[:search] = value
  end

  o.on '-n', '--neighbour', String, 'CSV-file with neighbour data.' do |value|
    CONFIG[:neighbours] << value
  end

  o.on '-N', '--neighbours', Array, 'Comma-separated list of CSV-files with neighbour data.' do |value|
    CONFIG[:neighbours] += value
  end

  o.on '-t', '--tops-count', Integer, 'Number of observers in top lists.' do |value|
    CONFIG[:tops][:count] = value
  end

  o.on '-T', '--tops-limit', Integer, 'Minimal numbers of species for observers in top lists.' do |value|
    CONFIG[:tops][:limit] = value
  end

  o.on '-f', '--file-output',
       "Write output to file(-s) instead of stdout. Output file",
       "has same base name as YAML-config and '.htm' extesion." do
    CONFIG[:file_output] = true
  end

  o.on '-1', '--no-threads', 'Do not use threads.' do
    CONFIG[:no_threads] = true
  end

end

rest = opts.parse ARGV

if rest == nil || rest.empty?
  CONFIG[:yaml] = ['./season-config.yaml']
else
  CONFIG[:yaml] = rest
end

if CONFIG[:yaml].size > 1 && CONFIG[:file_output] && !CONFIG[:no_threads]
  CONFIG[:yaml].each do |yaml|
    Thread::new yaml, CONFIG.dup { |t, c| do_task(t, c) }
  end
  Thread::list.each(&:join)
else
  CONFIG[:yaml].each do |yaml|
    do_task yaml, CONFIG.dup
  end
end
