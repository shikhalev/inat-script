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

def do_task task, config
  yaml = get_yaml task
  conf = YAML.load_file yaml
  config[:source] = conf['source'] if conf['source']
  config[:search] = conf['search'] if conf['search']
  config[:neighbours] += conf['neighbours'] if conf['neighbours']

  get_season = proc do |date|
    date.year.to_s
  end
  if config[:months] && config[:months][:first] && config[:months][:last] && config[:months][:first] > config[:months][:last]
    get_season = proc do |date|
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
    row_data = row.to_h.slice :quality_grade, :observed_on, :scientific_name, :common_name, :taxon_id, :user_login, :url, :id
    if row_data[:quality_grade] == 'research'
      date = Date::parse row_data[:observed_on]
      row_data[:season] = get_season[date]
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


  html = "<h2>Итоги сезона</h2>\n\n"

  html << "Здесь и далее учитываются только наблюдения исследовательского уровня, если специально не оговорено иное.\n\n"

  html << "<h3>История</h3>\n\n"

  html << "<table>\n\n"
  html << "<tr>\n"
  html << "<th>Сезон</th>"
  html << "<th>Наблюдения</th>"
  html << "<th>Виды</th>"
  html << "<th>Новые</th>"
  html << "\n</tr>\n"

  stats[..-2].each do |row|
    observations_link = config[:search] + '&quality_grade=research' + season_query[row[:season]]
    species_link = observations_link + '&view=species'
    html << "\n<tr>\n"
    html << "<td>#{row[:season]}</td>\n"
    html << "<td><a href=\"#{observations_link}\">#{row[:observations]}</a></td>\n"
    html << "<td><a href=\"#{species_link}\">#{row[:species]}</a></td>\n"
    html << "<td>#{row[:news]}</td>"
    html << "\n</tr>\n"
  end
  row = stats[-1]
  observations_link = config[:search] + '&quality_grade=research' + season_query[row[:season]]
  species_link = observations_link + '&view=species'
  html << "\n<tr>\n"
  html << "<td><b>#{row[:season]}</b></td>\n"
  html << "<td><a href=\"#{observations_link}\"><b>#{row[:observations]}</b></a></td>\n"
  html << "<td><a href=\"#{species_link}\"><b>#{row[:species]}</b></a></td>\n"
  html << "<td><b>#{row[:news]}</b></td>"
  html << "\n</tr>\n"

  html << "\n</table>\n"

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
    sorted_news = last_news.to_a.sort_by { |n| n[0] }
    html << "\n<h3>Новинки</h3>\n\n"
    html << "Виды, в предыдущие сезоны не наблюдавшиеся.\n\n"
    html << "\n<table>\n"
    html << "\n<tr>\n"
    html << "<th>Вид</th>"
    html << "<th>Наблюдения</th>"
    html << "\n</tr>\n"

    sorted_news.each do |nn|
      scientific_name = nn[0]
      observations = nn[1]
      common_name = observations[0][:common_name]
      taxon_id = observations[0][:taxon_id]
      html << "\n<tr>\n"
      html << "<td><a href=\"https://www.inaturalist.org/taxa/#{taxon_id}\">#{common_name} <i>(#{scientific_name})</i></a></td>\n"
      html << "<td>"
      html << observations.map { |o| "<a href=\"#{o[:url]}\">\##{o[:id]}</a>#{news_user_link[o[:user_login]]}" }.join(', ')
      html << "</td>"
      html << "\n</tr>\n"
    end

    html << "\n</table>\n\n"
  end
  html << "\nНовые виды наблюдали:\n\n"
  html << "<ul>\n"
  html << news_users.to_a.sort_by { |u| u[1] }.map { |u| "<li><a name=\"news-user-#{u[1]}\">[#{u[1]}]</a> @#{u[0]}</li>" }.join("\n")
  html << "\n</ul>\n\n"

  top_users = []
  users_for_top.each do |key, value|
    top_users << [key, value.size, value.to_a.sum { |x| x[1] }]
  end
  top_users.filter! { |v| v[1] >= 10 }
  top_users.sort_by! { |v| v[1] }
  top_users.reverse!
  top_users_last = []
  users_for_top_last.each do |key, value|
    top_users_last << [key, value.size, value.to_a.sum { |x| x[1] }]
  end
  top_users_last.filter! { |v| v[1] >= 10 }
  top_users_last.sort_by! { |v| v[1] }
  top_users_last.reverse!

  if top_users.size > 0
    html << "\n<h3>Лучшие наблюдатели</h3>\n\n"
    html << "Топ наблюдателей <i>по числу видов</i>. Показаны топ-10 из тех, у кого число видов больше 10.\n\n"
    html << "\n<h4>За все время</h4>\n\n"
    html << "\n<table>\n\n"
    html << "\n<tr>\n\n"
    html << "<th>\#</th><th>Наблюдатель</th><th>Виды</th><th>Наблюдения</th>"
    html << "\n</tr>\n\n"
    top_users[0..9].each_with_index do |u, i|
      html << "\n<tr>\n"
      html << "<td>#{i + 1}</td>"
      html << "<td>@#{u[0]}</td>"
      html << "<td>#{u[1]}</td>"
      html << "<td>#{u[2]}</td>"
      html << "\n</tr>\n"
    end
    html << "\n</table>\n\n"
    if top_users_last.size > 0
      html << "\n<h4>За сезон</h4>\n\n"
      html << "\n<table>\n\n"
      html << "\n<tr>\n\n"
      html << "<th>\#</th><th>Наблюдатель</th><th>Виды</th><th>Наблюдения</th>"
      html << "\n</tr>\n\n"
      top_users_last[0..9].each_with_index do |u, i|
        html << "\n<tr>\n"
        html << "<td>#{i + 1}</td>"
        html << "<td>@#{u[0]}</td>"
        html << "<td>#{u[1]}</td>"
        html << "<td>#{u[2]}</td>"
        html << "\n</tr>\n"
      end
      html << "\n</table>\n\n"
    end
  end

  #pp last_news

  if config[:file_output]
    filename = File.basename(File.basename(task, '.yml'), '.yaml')
    File::open filename + '.htm', 'w' do |f|
      f.puts html
    end
  else
    $stdout.puts html
  end

  # TODO: this
end

CONFIG = {
  :yaml => nil,
  :months => {
    :first => 1,
    :last => 12
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

  o.on '--first-month', Integer, 'Month from which the period starts [1-12].' do |value|
    CONFIG[:months][:first] = value
  end

  o.on '--last-month', Integer, 'Month which the period ends [1-12].' do |value|
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
