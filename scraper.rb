#!/usr/bin/ruby
require 'rubygems'
require 'date'
require 'uri'
require 'fileutils'
require 'net/http'
require 'nokogiri'
require 'digest'
require 'json'

class Logger
	def initialize(filename)
		@log = File.open(filename, 'w+')
	end

	def <<(msg)
		puts msg
		@log.puts msg
		@log.flush
	end
end

class Strip
	attr_reader :config_file, :config
	attr_reader :name, :source, :dates

	def initialize(config_file)
		@config_file = config_file
		@config = JSON.parse(File.open(@config_file).read, :symbolize_names => true)

		@name = @config[:name]
		$logger << "name: #{@name.inspect}"
		@source = @config[:source]
		$logger << "source: #{@source.inspect}"
		start_date = parse_date(@config[:start_date])
		$logger << "start date: #{start_date.to_s}"
		end_date = parse_date(@config[:end_date])
		$logger << "end date: #{end_date.to_s}"
		@dates = (start_date..end_date)

		@config[:exclude_files] ||= [ ]
		@config[:exclude_files].each do |filename|
			$logger << "exclude file #{filename}"
		end
		@config[:exclude_uris] ||= [ ]
		@config[:exclude_uris].each do |uri|
			$logger << "exclude uri #{uri}"
		end

		@sha256 = Digest::SHA256.new
		@hashes = Hash.new { |h, k| h[k] = Array.new }

		Dir[filename(nil)].each do |file|
			if excluded?(file)
				$logger << "#{file} deleted as excluded"
				File.delete(file)
			else
				add_file(file)
			end
		end
	end

	def finalize
		File.open(@config_file, 'w') { |f| f.write(JSON.pretty_generate(@config)) }

		@config[:exclude_files].each do |exclude|
			File.delete(exclude) rescue nil
		end
	end

	def uri(date)
		URI("http://www.gocomics.com/#{@source}/#{date.strftime('%Y/%m/%d')}")
	end

	def filename(date = nil)
		"#{@source}-#{date.nil? ? '*' : date.strftime('%F')}.gif"
	end

	def each_date(&block)
		@dates.each do |date|
			yield(date)
		end
	end

	def has_file?(filename)
		[ @hashes.values, @config[:exclude_files] ].flatten.include?(filename)
	end

	def add_file(filename, uri = nil)
		@sha256.reset
		hash = @sha256.file(filename).hexdigest
		if @hashes.has_key?(hash)
			$logger << "#{filename} known, hash = #{hash}"
			exclude_file(filename, uri)
		else
			$logger << "#{filename} added, hash = #{hash}"
			@hashes[hash] << filename
			@hashes[hash] << uri unless uri.nil?
		end
	end

	def exclude_file(filename, uri = nil)
		@config[:exclude_files] << filename
		@config[:exclude_uris] << uri unless uri.nil?
	end

	def excluded?(filename, uri = nil)
		return true if @config[:exclude_files].include?(filename)
		@config[:exclude_uris].include?(uri) unless uri.nil?
		false
	end

	def has_uri?(uri)
		[ @hashes.values, @config[:exclude_uris] ].flatten.include?(uri)
	end

	private

	def parse_date(date, default = Date.today)
		return default if date.nil? or date.empty?
		Date.parse(date) rescue default
	end
end

strip_name = ARGV.shift
$logger = Logger.new("#{strip_name}.log")
$strip = Strip.new("#{strip_name}.conf")

$strip.each_date do |date|
	filename = $strip.filename(date)
	next if $strip.has_file?(filename)

	uri = $strip.uri(date)
	body = Net::HTTP.get(uri)
	html = Nokogiri::HTML(body)
	img = html.css('div > img.strip')
	src = img.first['src'] rescue nil
	if src.nil?
		img = html.css('p > img.strip')
		src = img.first['src'] rescue nil
	end
	if src.nil?
		$logger << "failed to get #{uri}"
		next
	end

	$logger << "#{src} --> #{filename}"

	if $strip.has_uri?(src)
		$strip.exclude_file(filename)
	else
		image = Net::HTTP.get(URI(src))
		File.open(filename, 'wb') { |f| f.write(image) }
		$strip.add_file(filename, src)
	end
end

$strip.finalize
