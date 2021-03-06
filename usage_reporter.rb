#
# usage_reporter.rb
#
# Provides approximate reporting of monthly usage to date according
#   to a specified billing period, including breakdown by index.
#
# Usage:
#   ruby monthly_usage_reporter.rb <username> <account API key> [billing period start date (number)]
#
# Disclaimer: this tool is offered for demonstration purposes only
#   and does not provide true audits of interaction counts due to
#   redaction and other platform limitations.
#   
# For accurate interaction accounting relevant to monthly billing, 
#   contact your Technical Account Manager for a total generated
#   by our data warehouse backend.


require_relative 'account_selector'
require 'datasift'
require 'json'
require 'active_support'
require 'active_support/core_ext/hash'
require 'active_support/number_helper'
require 'terminal-table'

PAGE_LENGTH = 1000

time = Time.now.localtime("-08:00")

unless ARGV.empty?
  config = {}
  config[:username], config[:api_key], billing_period_start = ARGV
  billing_period_start = billing_period_start.to_i if billing_period_start
else
  # TODO: add feature to select arbitrary accounts for reporting from identities.yml
  account ||= :default
  config, options = AccountSelector.select account, :admin, with_billing_start: true
  billing_period_start = options[:billing_start]
end
billing_period_start ||= 1

admin_client = DataSift::Pylon.new(config)

page = 0
pages = 1

def find_valid_date(year, month, day)
  valid = Date.valid_date?(year, month, day)
  until valid
    day -= 1
    valid = Date.valid_date?(year, month, day)
  end
  Date.new(year, month, day)
end

def delimit(value)
  ActiveSupport::NumberHelper.number_to_delimited(value)
end

# calculate beginning of billing period
# TODO: simplify? decrement month by 1 if condition is met. Send both through #find_valid_date

if time.day < billing_period_start
  billing_start_date = find_valid_date(time.year, time.month - 1, billing_period_start)
else
  billing_start_date = Date.new(time.year, time.month, billing_period_start)
end
billing_start_time = Time.new(billing_start_date.year, billing_start_date.month, billing_start_date.day, 0, 0, 0, "-08:00")

puts "[Start] Calculating consumption for the billing period beginning on #{ billing_start_date.to_s }"

identities = {}
indexes_by_identity = {}
indexes_by_volume = {}
volume_by_index = {}
indexes_found = 0
volume = 0
# missing_segments = 0 (not generally possible if an index is stopped & started)
redacted_indexes = []
indexes_for_analysis = []

until page == pages
  page += 1
  response = admin_client.list(page, PAGE_LENGTH)
  pages = response[:data][:pages]

  # TODO: Handle empty susbcriptions array
  indexes = response[:data][:subscriptions]
  if indexes.nil? || (indexes && indexes.empty?)
    puts "[Error] No indexes found for this account. Did you remember to use your account API key?"
  end

  indexes.each do |index|
    # qualify index based on time
    next unless (index[:status] == "running" && index[:end].nil?) || (index[:status] == "stopped" && index[:end] > billing_start_time.to_i)
    indexes_found += 1

    indexes_by_identity[index[:identity_id]] ||= {}
    indexes_by_identity[index[:identity_id]][index[:id]] = index
    
    if index[:start] >= billing_start_time.to_i
      # index has run only inside the billing period
      indexes_by_volume[index[:volume]] ||= []
      indexes_by_volume[index[:volume]] << index
      volume_by_index[index[:id]] = index[:volume]
      volume += index[:volume]
      # puts "No analysis necessary for index #{ index[:id] }"
    else # run analysis query for volume
      indexes_for_analysis << index[:id]
    end
  end
end

puts "[Done] Index identification complete."
puts "  * Found #{ indexes_found } indexes, #{ indexes_for_analysis.length } of which require analysis.
    This will consume #{ indexes_for_analysis.length * 25 } points from your hourly PYLON /analyze API limit."
puts "  * Indexes first created in this billing period represent #{ delimit(volume) } interactions."

page, pages = 0, 1
identity_client = DataSift::AccountIdentity.new(config)

# TODO: Cannot query for indexes whose identities are inactive

analyze_count = 0
time_series_params = { analysis_type: "timeSeries", parameters: { interval: "day" }}
first_analysis_query = true

puts "[Start] Fetching identity information"

until page == pages
  page += 1
  response = identity_client.list('', PAGE_LENGTH.to_s, 1.to_s)
  identity_list = response[:data][:identities]
  identity_list.each do |identity|
    identities[identity[:id]] = identity
    # run logic for required analyses
    indexes = indexes_by_identity[identity[:id]]
    next unless indexes && (indexes_for_analysis & indexes.keys).length > 0
    indexes.each do |id, index|
      next unless indexes_for_analysis.include?(id)

      if first_analysis_query
        print "[Working] Executing analysis queries (#{ indexes_for_analysis.length} total): "
        first_analysis_query = false
      end

      client = DataSift::Pylon.new(config.merge(:api_key => identity[:api_key]))
      analysis_start = billing_start_time.to_i
      response = client.analyze('', time_series_params, '', analysis_start, nil, id)
      analyze_count += 1
      print "#{ analyze_count } "
      unless response[:data][:analysis][:redacted]
        # puts response.inspect
        index_volume = response[:data][:interactions]
        index[:identity_name] = identity[:label]
        indexes_by_volume[index_volume] ||= []
        indexes_by_volume[index_volume] << index
        volume_by_index[id] = index_volume
        volume += index_volume
      else
        volume_by_index[id] = 0
        redacted_indexes << id
      end
      indexes_for_analysis.delete(index)
    end
  end
end
puts "100%"

puts "[Done] Analyzed target indexes. #{ redacted_indexes.length } indexes were redacted."
puts "  * The final volume count is: #{ delimit(volume) } interactions."

puts "\nUsage Summary:"

table = Terminal::Table.new(
  headings: ["User Name", "Billing Start Date", "Total Usage", "Generated At"],
  rows: [[config[:username], billing_start_date.to_s, delimit(volume), time.to_s ]])
puts table

puts "\nUsage Totals by Index:"

table = Terminal::Table.new({ :headings => ["Volume", "Status", "Index Name", "Identity", "Index ID"] }) do |t|
  indexes_by_volume.keys.sort.reverse.each do |index_volume|
    indexes = indexes_by_volume[index_volume]
    indexes.each do |index|
      identity_name = index[:identity_name] || identities[index[:identity_id]][:label]
      formatted_volume = delimit(index_volume)
      t.add_row [formatted_volume, index[:status], index[:name], identity_name, index[:id]]
    end
  end
end
table.align_column(0, :right)
puts table

puts "\nDisclaimer: These totals are approximations only and may not accurately represent interaction totals
  for official billing purposes."

puts