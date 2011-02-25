#!/usr/bin/env ruby
# arteget 
# Copyright Raphaël Rigo
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
	puts "Usage : arteget [-v] (--best=NUM|--top=NUM)|URL|program"
end

def parse_xml(hc, xml_url, progname=nil)
	xml_content = hc.get(xml_url).content
	xml = Document.new(xml_content)
	result = []
	xml.root.each_element("video") do |e|
		if progname and e.get_text('title').to_s !~ /#{progname}/i
			next
		end
		t=[e.get_text('targetUrl'),e.get_text('title'),e.get_text('teaserText')]
		t.map! {|e| e.to_s.gsub("\n","") }
		result << t
	end
	return result
end

def get_progs_urls(hc, progname)
	if progname =~ /^http:/ then
		log("Trying with URL")
		return progname
	end
	log("Getting index")

	index = hc.get('/fr/videos').content
	xml_url = index[/coverflowXmlUrl = "(.*)"/,1]

	log(xml_url, LOG_DEBUG)
	fatal("Cannot find index list") if not xml_url 

	if $options[:best] then
		bestnum = $options[:best]
		log("Getting best #{bestnum} list page")
		result = parse_xml(hc, xml_url+"?hash=/tv/coverflow/popular/bestrated/1/#{bestnum}/")
		pp result
		exit
	elsif $options[:top] then
		topnum = $options[:top]
		log("Getting top #{topnum} list page")
		result = parse_xml(hc, xml_url+"?hash=/tv/coverflow/popular/mostviewed/1/#{topnum}/")
		pp result
		exit
	else
		log("Getting list page")
		result = parse_xml(hc, xml_url, progname)
		pp result
		exit
		index_list = hc.get(xml_url).content
		result = [index_list[/href="(.*\/#{progname}.*\.html)"/,1]]

		if not result then
			log("Could not find program in list, trying another way")
			log("Getting program page")
			result = index[/href="(.*\/#{progname}.*\.html)"/,1]
			fatal("Could not find program page") if not result
			prog_page = hc.get(result).content
			prog_list_url = prog_page[/listViewUrl: "(.*)"/,1]
			fatal("Cannot find list for program") if not prog_list_url

			log("Getting list page")
			prog_list = hc.get(prog_list_url).content
			result = [prog_list[/href="(.*\.html)"/,1]]
		end
		fatal("Cannot find program at all") if not result
	end
	return result
end

begin 
	OptionParser.new do |opts|
		opts.on('-v', "--verbose") { |v| $options[:log] = LOG_DEBUG }
		opts.on('-b', "--best=NUM") { |n| $options[:best] = n.to_i }
		opts.on('-t', "--top=NUM") { |n| $options[:top] = n.to_i }
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

hc = HttpClient.new("videos.arte.tv")
hc.allowbadget = true

program_page_url = get_progs_urls(hc, progname)
log(program_page_url, LOG_DEBUG)

vid_id = program_page_url[/-(.*)\./,1]
fatal("No video id in URL") if not vid_id
fatal("Already downloaded") if Dir["*#{vid_id}*"].length > 0 

log("Getting video page")
page_video = hc.get(program_page_url).content
videoref_url = page_video[/videorefFileUrl = "http:\/\/videos.arte.tv(.*\.xml)"/,1]
player_url = page_video[/url_player = "(.*\.swf)"/,1]
log(videoref_url, LOG_DEBUG) 
log(player_url, LOG_DEBUG) 

log("Getting video XML desc")
videoref_content = hc.get(videoref_url).content
log(videoref_content, LOG_DEBUG)
ref_xml = Document.new(videoref_content)
vid_lang_url = ref_xml.root.elements["videos/video[@lang='#{$options[:lang]}']"].attributes['ref']
vid_lang_url.gsub!(/.*arte.tv/,'')
log(vid_lang_url, LOG_DEBUG)

log("Getting #{$options[:lang]} #{$options[:qual]} video XML desc")
vid_lang_xml_url = hc.get(vid_lang_url).content
vid_lang_xml = Document.new(vid_lang_xml_url)
rtmp_url = vid_lang_xml.root.elements["urls/url[@quality='#{$options[:qual]}']"].text
log(rtmp_url, LOG_DEBUG)

log("Dumping video : #{vid_id}.flv")
log("rtmpdump --swfVfy #{player_url} -o #{vid_id}.flv -r \"#{rtmp_url}\"", LOG_DEBUG)
fork do 
	exec("rtmpdump", "-q", "--swfVfy", player_url, "-o", "#{vid_id}.flv", "-r", rtmp_url)
end
Process.wait
if $?.exited?
	case $?.exitstatus
		when 0 then
			log("Video successfully dumped")
		when 1 then
			fatal("rtmpdump failed")
		when 2 then
			log("rtmpdump exited, trying to resume")
			exec("rtmpdump", "-e", "-q", "--swfVfy", player_url, "-o", "#{vid_id}.flv", "-r", rtmp_url)
	end
end

