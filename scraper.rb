require 'scraperwiki'
require 'mechanize'
require 'geokit'
require 'pry'
require 'reverse_markdown'

# Set an API key if provided
Geokit::Geocoders::GoogleGeocoder.api_key = ENV['MORPH_GOOGLE_API_KEY'] if ENV['MORPH_GOOGLE_API_KEY']

@mappings = {
  'Trade name' => 'trading_name',
  'Name of convicted' => 'name_of_convicted',
  'Usual place of business' => 'place_of_business',
  'Council area' => 'council',
  'Council Area' => 'council',
  'Address at which offence was committed' => 'offence_address',
  'Date of offence' => 'offence_date',
  'Nature and circumstances of offence' => 'description',
  'Nature & circumstances of offence' => 'description',
  'Date of decision' => 'decision_date',
  'Decision' => 'decision',
  'Court' => 'court',
  'Penalty' => 'penalty',
  'Decision details' => 'decision_details',
  'Prosecution brought by or for' => 'prosecution_brought_by',
  'Notes' => 'notes',
}

def scrub(text)
  text.gsub!(/[[:space:]]/, ' ') # convert all utf whitespace to simple space
  text.strip
end

def get(url)
  @agent ||= Mechanize.new
  @agent.get(url)
end

def extract_detail(page)
  details = {}

  rows = page.search('div.contentInfo table tbody tr').children.map {|e| e.text? ? nil : e }.compact

  rows.each_slice(2) do |key, value|
    k = scrub(key.text)
    case
    when @mappings[k]
      field = @mappings[k]
    when id = @mappings.keys.find {|matcher| k.match(matcher)}
      field = @mappings[id]
    else
      #binding.pry
      raise "unknown field for '#{k}'"
    end

    if field == 'description'
      text = ReverseMarkdown.convert(value.children.map(&:to_s).join)
    else
      text = scrub(value.text)
    end

    details.merge!({field => text})
  end

  return details
end

def extract_notices(page)
  notices = []
  page.search('div.contentInfo div.table-container tbody tr').each do |el|
    notices << { 'link' => "#{base}#{el.search('a').first['href']}" }
  end
  notices
end

def build_notice(notice)
  page    = get(notice['link'])
  details = extract_detail(page)
  puts "Extracting #{details['offence_address']}"
  notice.merge!(details)
end

def geocode(notice)
  puts "Geocoding #{notice['offence_address']}"
  a = Geokit::Geocoders::GoogleGeocoder.geocode(notice['offence_address'])
  location = {
    'lat' => a.lat,
    'lng' => a.lng,
  }
  notice.merge!(location)
end

def base
  "http://www.foodauthority.nsw.gov.au"
end

def existing_record_ids
  return @cached if @cached
  @cached = ScraperWiki.select('link from data').map {|r| r['link']}
rescue SqliteMagic::NoSuchTable
  []
end

def main
  page = get("#{base}/offences/prosecutions")

  notices = extract_notices(page)
  puts "### Found #{notices.size} notices"
  new_notices = notices.select {|r| !existing_record_ids.include?(r['link']) }
  puts "### There are #{new_notices.size} new notices"

  new_notices.map! {|n| build_notice(n) }
  new_notices.reject! {|n| n.keys.size == 1 }
  new_notices.map! {|n| geocode(n) }

  # Serialise
  ScraperWiki.save_sqlite(['link'], new_notices)

  puts "Done"
end

main()
