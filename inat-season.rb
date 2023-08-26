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
  attr_reader :iconic_taxon_order
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
      @iconic_taxon_name = src.iconic_taxon_name || 'Unknown'
      src.observations.each do |observation|
        @observations << observation
      end
    else
      load src, :taxon_id, :scientific_name, :common_name, :iconic_taxon_name
    end
    @iconic_taxon_order = ICONIC_ORDER[@iconic_taxon_name] || 20
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

  def url
    "https://www.inaturalist.org/taxa/#{@taxon_id}"
  end

  def html_title
    base = if @common_name
      "#{@common_name.gsub(' ', ' ')} <i>(#{@scientific_name.gsub(' ', ' ')})</i>"
    else
      "<i>#{@scientific_name.gsub(' ', ' ')}</i>"
    end
    "<a href=\"#{url}\"><i class=\"icon-iconic-#{@iconic_taxon_name.downcase}\" style=\"font-size: 1.5em; height: 1em; line-height: 1em;\"></i> #{base}</a>"
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
    @taxa.to_a.map { |i| i[1] }.sort_by { |i| i.scientific_name }.each &block
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
      @taxa[item.taxon_id] = Taxon::new item, @config
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

  def split_seasons
    result = Seasons::new @config
    each do |taxon|
      taxon.each do |observation|
        result << observation
      end
    end
    result
  end

  def split_observers
    result = Observers::new @config
    each do |taxon|
      taxon.each do |observation|
        result << observation
      end
    end
    result
  end

  def has_id? taxon_id
    @taxa.member? taxon_id
  end

  def + other
    merge other
  end

  def - other
    result = self.same
    each do |taxon|
      result << taxon if !other.has_id?(taxon.taxon_id)
    end
    result
  end

  def html_list details: true, observers: true, subtitle: nil
    @@unikey ||= 0
    @@unikey += 1
    result = []
    result << '<table>'
    result << '<tr>'
    result << '<th style="text-align: right; width: 3em;">#</th>'
    result << '<th>Таксон</th>'
    if details
      result << '<th>Наблюдения</th>'
    else
      result << '<th style="text-align: right; width: 5em;">Наблюдения</th>'
    end
    result << '</tr>'

    numbers = {}
    if details && observers
      splitted = split_observers
      bottom = []
      bottom << ''
      bottom << "<h4>#{subtitle}</h4>" if subtitle
      bottom << '<table>'
      bottom << '<tr>'
      bottom << '<th style="text-align: right; width: 3em;">#</th>'
      bottom << '<th>Логин</th>'
      bottom << '<th style="text-align: right; width: 5em;">Виды</th>'
      bottom << '<th style="text-align: right; width: 5em;">Наблюдения</th>'
      bottom << '</tr>'
      number = 0
      splitted.each do |observer|
        bottom << '<tr>'
        number += 1
        numbers[observer.user_login] = number
        bottom << "<td style=\"text-align: right; width: 3em;\">#{number}</td>"
        bottom << "<td><a name=\"#{@@unikey}-#{observer.user_login}\"><i class=\"glyphicon glyphicon-user\"></i></a> @#{observer.user_login}</td>"
        bottom << "<td style=\"text-align: right; width: 5em;\">#{observer.taxon_count}</td>"
        bottom << "<td style=\"text-align: right; width: 5em;\">#{observer.observation_count}</td>"
        bottom << '</tr>'
      end
      bottom << '</table>'
    end

    list_num = 0
    @taxa.to_a.map { |t| t[1] }.sort_by { |t| t.scientific_name }.sort_by { |t| t.iconic_taxon_order }.each do |taxon|
      result << '<tr>'
      list_num += 1
      result << "<td style=\"text-align: right; width: 3em;\">#{list_num}</td>"
      result << "<td>#{taxon.html_title}</td>"
      if details
        result << '<td>'
        olist = []
        taxon.each do |observation|
          ulink = if observers
            "<sup><a href=\"\##{@@unikey}-#{observation.user_login}\" title=\"#{observation.user_login}\">#{numbers[observation.user_login]}</a></sup>"
          else
            ''
          end
          olist << "<a href=\"#{observation.url}\">\##{observation.id}</a>#{ulink}"
        end
        result << olist.join(', ')
      else
        result << '<td style="text-align: right; width: 5em;">'
        result << taxon.observation_count.to_s
      end
      result << '</td>'
      result << '</tr>'
    end

    result << '</table>'

    if details && observers
      result += bottom
    end

    result.join("\n")
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

  def [] season
    @seasons[season]
  end

  def << observation
    season_name = observation.season
    @seasons[season_name] ||= Season::new season_name, @config
    @seasons[season_name] << observation
  end

  def each &block
    @seasons.to_a.map { |s| s[1] }.sort_by { |s| s.season }.each &block
  end

  def last_name
    @seasons.to_a.map { |s| s[1].season }.sort.last
  end

  def html_history
    result = []
    result << "<table>"
    result << "<tr>"
    result << "<th style=\"text-align: right; width: 3em;\">#</th>"
    result << "<th>Сезон</th>"
    result << "<th style=\"text-align: right; width: 5em;\">Наблюдения</th>"
    result << "<th style=\"text-align: right; width: 5em;\">Виды</th>"
    result << "<th style=\"text-align: right; width: 5em;\">Новые</th>"
    result << "</tr>"

    num = 0
    olds = List::new @config
    each do |season|
      num += 1
      name = season.season
      observation_count = season.observation_count
      taxon_count = season.taxon_count
      news = season - olds
      news_count = news.taxon_count
      olds.merge! season if name != last_name
      bold = 'font-weight: bold; font-size: 1.1em;' if name == last_name
      result << "<tr>"
      result << "<td style=\"text-align: right; width: 3em;\">#{num}</td>"
      result << "<td style=\"#{bold}\"><i class=\"glyphicon glyphicon-calendar\"></i> #{name}</td>"
      result << "<td style=\"text-align: right;#{bold}; width: 5em;\">#{observation_count}</td>"
      result << "<td style=\"text-align: right;#{bold}; width: 5em;\">#{taxon_count}</td>"
      result << "<td style=\"text-align: right;#{bold}; width: 5em;\">#{news_count}</td>"
      result << "</tr>"
    end
    @olds = olds
    @news = news

    result << "</table>"
    result.join("\n")
  end

  def news
    if !@news
      season = @seasons[last_name]
      @news = season - olds
    end
    @news
  end

  def olds
    if !@olds
      @olds = List::new @config
      each do |season|
        @olds.merge! season if season.season != last_name
      end
    end
    @olds
  end

  def lost
    list = @seasons.to_a.map { |s| s[1] }.sort_by { |s| s.season }
    old_list = list[0 .. -@config[:modern] - 1]
    new_list = list[-@config[:modern] .. -1]
    olds = List::new @config
    old_list.each do |season|
      olds.merge! season
    end
    news = List::new @config
    new_list.each do |season|
      news.merge! season
    end
    olds - news
  end

  def all
    if !@all
      @all = List::new @config
      each do |season|
        @all.merge! season
      end
    end
    @all
  end

  def last
    self[last_name]
  end

  def ones
    result = List::new @config
    all.each do |taxon|
      result << taxon if taxon.observation_count == 1
    end
    result
  end

end

class Observer < List

  attr_reader :user_login

  def initialize user_login, config
    @user_login = user_login
    super config
  end

  def << item
    case item
    when Taxon
      item.each do |observation|
        self << observation
      end
    when Observation
      if item.user_login == @user_login
        super item
      end
    end
    self
  end

end

class Observers

  def initialize config
    @config = config
    @observers = {}
  end

  def [] user_login
    @observers[user_login]
  end

  def << observation
    user_login = observation.user_login
    @observers[user_login] ||= Observer::new user_login, @config
    @observers[user_login] << observation
  end

  def each &block
    @observers.to_a.map { |o| o[1] }.sort_by { |o| o.taxon_count }.reverse.each &block
  end

  def html_top subtitle: nil
    data = @observers.to_a.map { |o| o[1] }.filter { |o| o.taxon_count >= @config[:tops][:limit] }.sort_by { |o| o.taxon_count }.reverse.take(@config[:tops][:count])
    result = []
    if data.size != 0
      result << "\n<h4>#{subtitle}</h4>" if subtitle
      result << ''
      result << '<table>'
      result << '<tr>'
      result << '<th style="text-align: right; width: 3em;">#</th>'
      result << '<th>Наблюдатель</th>'
      result << '<th style="text-align: right; width: 5em;">Виды</th>'
      result << '<th style="text-align: right; width: 5em;">Наблюдения</th>'
      result << '</tr>'
      num = 0
      data.each do |observer|
        num += 1
        result << '<tr>'
        result << "<td style=\"text-align: right; width: 3em;\">#{num}</td>"
        result << "<td><i class=\"glyphicon glyphicon-user\"></i> @#{observer.user_login}</td>"
        result << "<td style=\"text-align: right; width: 5em;\">#{observer.taxon_count}</td>"
        result << "<td style=\"text-align: right; width: 5em;\">#{observer.observation_count}</td>"
        result << '</tr>'
      end
      result << '</table>'
    end
    result.join("\n")
  end

end


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
  config[:modern] = conf['modern'] if conf['modern']

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

  seasons = Seasons::new config
  needs_ids = List::new config

  csv = CSV::table(config[:source])
  csv.each do |row|
    observation = Observation::new row, config
    if observation.quality_grade == 'research'
      seasons << observation
    elsif observation.quality_grade == 'needs_id'
      needs_ids << observation
    end
  end

  html = []

  html << "<h2>Итоги сезона #{seasons.last_name}</h2>"
  html << ''
  html << '<h3>История</h3>'
  html << ''
  html << 'Здесь и далее рассматриваются только наблюдения исследовательского уровня, если отдельно и явно не оговорено иное.'
  html << ''
  html << seasons.html_history

  html << ''
  html << '<h3>Лучшие наблюдатели</h3>'
  html << ''
  html << "Топ-#{config[:tops][:count]} наблюдателей (среди тех у кого не менее #{config[:tops][:limit]} видов)."
  html << ''
  last_season = seasons.last.split_observers
  html << last_season.html_top(subtitle: 'За сезон')
  all_time = seasons.all.split_observers
  html << all_time.html_top(subtitle: 'За всё время')

  html << ''
  html << '<h3>Новинки</h3>'
  html << ''
  html << 'Таксоны, наблюдавшиеся в данном сезоне впервые.'
  html << ''
  html << seasons.news.html_list(subtitle: 'Наблюдатели новинок')

  lost = seasons.lost
  if lost.taxon_count != 0
    html << ''
    html << '<h3>«Потеряшки»</h3>'
    html << ''
    html << "Ранее найденные таксоны без подтвержденных наблюдений в последние #{config[:modern]} сезона."
    html << ''
    html << lost.html_list(observers: false)
  end


  if config[:neighbours].size != 0
    html << ''
    html << '<h2>Сравнение с соседями</h2>'
    html << ''
    neighbours = List::new config
    config[:neighbours].each do |filename|
      ncsv = CSV::table(filename)
      ncsv.each do |row|
        observation = Observation::new row, config
        if observation.quality_grade == 'research'
          neighbours << observation
        end
      end
    end
    uniqs = seasons.all - neighbours
    if uniqs.taxon_count != 0
      html << '<h3>«Уники»</h3>'
      html << ''
      html << 'Таксоны, не обнаруженные ни у кого из соседей.'
      html << ''
      html << uniqs.html_list(subtitle: 'Наблюдатели уников')
    end
    wanted = neighbours - seasons.all
    if wanted.taxon_count != 0
      html << '<h3>«Разыскиваются»</h3>'
      html << ''
      if wanted.taxon_count <= 500
        html << 'Таксоны, обнаруженные у соседей, но (пока?) не найденные здесь.'
        html << ''
        html << wanted.html_list(observers: false)
      else
        html << "Здесь должен быть список таксонов, обнаруженных у соседей, но не зафиксированных здесь. " +
                "Но поскольку их оказалось <b>#{wanted.taxon_count}</b>, такой список малочитаем и совершенно неинформативен."
      end
    end
    if uniqs.taxon_count == 0 || wanted.taxon_count == 0
      html << 'Не найдены различия с соседями.'
    end
    html << ''
  end

  html << '<h2>Недостаточно наблюдений</h2>'
  html << ''
  html << 'Таксоны, находок которых мало. Желательно обратить на них дополнительное внимание.'
  html << ''
  html << '<h3>Только одно подтвержденное наблюдение</h3>'
  html << ''
  html << seasons.ones.html_list(observers: false)
  html << ''
  html << '<h3>Только неподтвержденные наблюдения</h3>'
  html << ''
  needs_id_only = needs_ids - seasons.all
  html << needs_id_only.html_list(observers: false)

  html << ''
  html << '<hr>'

  html << '<hr>'
  html << ''
  html << '<small>Таблицы в данном посте составлены посредством скрипта, который можно найти по адресу: ' +
          '<a href="https://github.com/shikhalev/inat-script">https://github.com/shikhalev/inat-script</a>.</small>'
  html << ''

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
  :modern => 3,
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

  o.on '-m', '--modern', Integer, 'Number of seasons considered modern.' do |value|
    CONFIG[:modern] = value
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
