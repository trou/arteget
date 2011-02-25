#!/usr/bin/env ruby
# arteget 
# Copyright 2008-2011 Raphaël Rigo
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA  02110-1301  USA

require 'pp'
require 'optparse'
require 'uri'
require 'libhttpclient'
require 'rexml/document'
include REXML

LOG_QUIET = 0
LOG_NORMAL = 1
LOG_DEBUG = 2

$options = {:log => LOG_NORMAL, :lang => "fr", :qual => "hd"}

def fatal(msg)
	puts msg
	exit(1)
end

def log(msg, level=LOG_NORMAL)
	puts msg if level <= $options[:log]
end

def print_usage
	puts "Usage : arteget [-v] [--qual=QUALITY] [--lang=LANG] --best[=NUM]|--top[=NUM]|URL|program"
	puts "\t-v\t--verbose\tdebug output"
	puts "\t-q\t--qual=hd|sd\tchoose quality, sd or hd (default)"
	puts "\t-l\t--lang=fr|de\tchoose language, german or french (default)"
	puts "\t-b\t--best[=NUM]\tdownload the NUM (10 default) best rated programs"
	puts "\t-t\t--top[=NUM]\tdownload the NUM (10 default) most viewed programs"
	puts "\tURL\t\t\tdownload the video on this page"
	puts "\tprogram\t\t\tdownload the latest avaiable broadcasts of \"program\""
end

# Find videos in the given XML url, keeping only the given program if specified
def parse_xml(xml_url, progname=nil)
	xml_content = $hc.get(xml_url).content
	xml = Document.new(xml_content)
	result = []
	xml.root.each_element("video") do |e|
		if progname and e.get_text('title').to_s !~ /#{progname}/i
			next
		end
		t=[e.get_text('targetUrl'),e.get_text('title'),e.get_text('teaserText')]
		t.map! {|e| REXML::Text::unnormalize(e.to_s).gsub("\n","") }
		result << t
	end
	return result
end

# Basically gets the lists of programs in XML format
# returns an array of arrays, containing 3 strings : [url, title, teaser]
def get_progs_urls(progname)
	if progname =~ /^http:/ then
		log("Trying with URL")
		return progname
	end
	log("Getting index")

	index = $hc.get("/#{$options[:lang]}/videos").content
	xml_url = index[/coverflowXmlUrl = "(.*)"/,1]

	log(xml_url, LOG_DEBUG)
	fatal("Cannot find index list") if not xml_url 

	if $options[:best] then
		bestnum = $options[:best]
		log("Getting best #{bestnum} list page")
		# ohhh magic !
		result = parse_xml(xml_url+"?hash=/tv/coverflow/popular/bestrated/1/#{bestnum}/")
	elsif $options[:top] then
		topnum = $options[:top]
		log("Getting top #{topnum} list page")
		result = parse_xml(xml_url+"?hash=/tv/coverflow/popular/mostviewed/1/#{topnum}/")
	else
		log("Getting list page")
		result = parse_xml(xml_url, progname)
	end
	fatal("Cannot find requested program(s)") if not result
	return result
end

def dump_video(page_url, title, teaser)
	log("Trying to get #{title}, teaser : \"#{teaser}\"")
	# ugly but the only way (?)
	vid_id = page_url[/-(.*)\./,1]
	return log("No video id in URL") if not vid_id
	return log("Already downloaded") if Dir["*#{vid_id}*"].length > 0 

	log("Getting video page")
	page_video = $hc.get(page_url).content
	videoref_url = page_video[/videorefFileUrl = "http:\/\/videos.arte.tv(.*\.xml)"/,1]
	player_url = page_video[/url_player = "(.*\.swf)"/,1]
	log(videoref_url, LOG_DEBUG) 
	log(player_url, LOG_DEBUG) 

	log("Getting video XML desc")
	videoref_content = $hc.get(videoref_url).content
	log(videoref_content, LOG_DEBUG)
	ref_xml = Document.new(videoref_content)
	vid_lang_url = ref_xml.root.elements["videos/video[@lang='#{$options[:lang]}']"].attributes['ref']
	vid_lang_url.gsub!(/.*arte.tv/,'')
	log(vid_lang_url, LOG_DEBUG)

	log("Getting #{$options[:lang]} #{$options[:qual]} video XML desc")
	vid_lang_xml_url = $hc.get(vid_lang_url).content
	vid_lang_xml = Document.new(vid_lang_xml_url)
	rtmp_url = vid_lang_xml.root.elements["urls/url[@quality='#{$options[:qual]}']"].text
	log(rtmp_url, LOG_DEBUG)

	log("Dumping video : #{vid_id}.flv")
	filename = vid_id+"_"+title.gsub(/[\/ "*:<>?|\\]/," ")+".flv"
	log("rtmpdump --swfVfy #{player_url} -o #{filename} -r \"#{rtmp_url}\"", LOG_DEBUG)
	fork do 
		exec("rtmpdump", "-q", "--swfVfy", player_url, "-o", filename, "-r", rtmp_url)
	end
	Process.wait
	if $?.exited?
		case $?.exitstatus
			when 0 then
				log("Video successfully dumped")
			when 1 then
				return log("rtmpdump failed")
			when 2 then
				log("rtmpdump exited, trying to resume")
				exec("rtmpdump", "-e", "-q", "--swfVfy", player_url, "-o", "#{vid_id}.flv", "-r", rtmp_url)
		end
	end
end

begin 
	OptionParser.new do |opts|
		opts.on('-v', "--verbose") { |v| $options[:log] = LOG_DEBUG }
		opts.on('-b', "--best[=NUM]") { |n| $options[:best] = n ? n.to_i : 10 }
		opts.on('-t', "--top[=NUM]") { |n| $options[:top] = n ? n.to_i : 10 }
		opts.on("-l", "--lang=LANG_ID") {|l| $options[:lang] = l }
		opts.on("-q", "--qual=QUAL") {|q| $options[:qual] = q }
	end.parse!
rescue OptionParser::InvalidOption	
	puts $!
	print_usage
	exit
end

if ARGV.length == 0 && !$options[:best] && !$options[:top]
	print_usage
	exit
elsif ARGV.length == 1
	progname=ARGV.shift
end

$hc = HttpClient.new("videos.arte.tv")
$hc.allowbadget = true

progs_data = get_progs_urls(progname)
log(progs_data, LOG_DEBUG)
log(progs_data.map {|a| a[1]+" : "+a[2]}.join("\n"))
progs_data.each {|p| dump_video(p[0], p[1], p[2]) }
