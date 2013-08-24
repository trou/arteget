#!/usr/bin/env ruby
# arteget 
# Copyright 2008-2013 Raphaël Rigo
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
require 'json'
require 'libhttpclient'

LOG_ERROR = -1
LOG_QUIET = 0
LOG_NORMAL = 1
LOG_DEBUG = 2

$options = {:log => LOG_NORMAL, :lang => "fr", :qual => "hd"}


def log(msg, level=LOG_NORMAL)
	puts msg if level <= $options[:log]
end

def error(msg)
	log(msg, LOG_ERROR)
end

def fatal(msg)
	error(msg)
	exit(1)
end

def print_usage
	puts "Usage : arteget [-v] [--qual=QUALITY] [--lang=LANG] --best[=NUM]|--top[=NUM]|URL|program"
	puts "\t\t--quiet\t\tonly error output"
	puts "\t-v\t--verbose\tdebug output"
	puts "\t-q\t--qual=hd|md|sd|ld\tchoose quality, hd is default"
	puts "\t-l\t--lang=fr|de\tchoose language, german or french (default)"
	puts "\t-b\t--best[=NUM]\tdownload the NUM (10 default) best rated programs"
	puts "\t-t\t--top[=NUM]\tdownload the NUM (10 default) most viewed programs"
	puts "\tURL\t\t\tdownload the video on this page"
	puts "\tprogram\t\t\tdownload the latest avaiable broadcasts of \"program\""
end

# Find videos in the given JSON array
def parse_json(progs)
	result = progs.map { |p| [p['url'], p['title'], p['desc']] }
	return result
end

# Basically gets the lists of programs in XML format
# returns an array of arrays, containing 3 strings : [url, title, teaser]
def get_progs_urls(progname)
	if progname =~ /^http:/ then
		log("Trying with URL")
		return [[progname, "", ""]]
	end
	log("Getting json")

	plus7 = $hc.get("/guide/#{$options[:lang]}/plus7.json").content
    plus7_j = JSON.parse(plus7)

	fatal("Cannot get program list JSON") if not plus7_j 

    vids = plus7_j["videos"]
	if $options[:best] then
		bestnum = $options[:best]
		log("Computing best #{bestnum}")
		# ohhh magic !
        fatal('TODO')
	elsif $options[:top] then
		topnum = $options[:top]
		log("Computing top #{topnum}")
        vids.sort! { |a, b| a["video_views"][/^[0-9 ]+/].gsub(' ','').to_i <=> b["video_views"][/^[0-9 ]+/].gsub(' ', '').to_i }.reverse!
        result = parse_json(vids[0,topnum])
	else
        # We have a program name
        progs = vids.find_all {|p| p["title"].casecmp(progname) == 0 }
        if progs != nil and progs.length > 0 then
		    result = parse_json(progs) 
        end
	end
	fatal("Cannot find requested program(s)") if result == nil or result.length == 0
	return result
end

def dump_video(page_url, title, teaser)
    if title == "" and teaser == "" then
        log("Trying to get #{page_url}")
    else
        log("Trying to get #{title}, teaser : \"#{teaser}\"")
    end
	# ugly but the only way (?)
	vid_id = page_url[/\/([0-9]+-[0-9]+)\//,1]
	return error("No video id in URL") if not vid_id

	log("Getting video page")
	page_video = $hc.get(page_url).content
	videoref_url = page_video[/arte_vp_url="http:\/\/arte.tv(.*PLUS7.*\.json)"/,1]
	log(videoref_url, LOG_DEBUG) 

	log("Getting video JSON desc")
	videoref_content = $hc.get(videoref_url).content
	log(videoref_content, LOG_DEBUG)
	vid_json = JSON.parse(videoref_content)

    # Fill metadata if needed
    if title == "" or teaser == "" then
        title = vid_json['videoJsonPlayer']['VTI']
        teaser = vid_json['videoJsonPlayer']['V7T']
        log(title+" : "+teaser)
    end

    good = vid_json['videoJsonPlayer']["VSR"].values.find do |v|
        v['quality'] =~ /^#{$options[:qual]}/i and
        v['mediaType'] == 'rtmp' and
        v['versionCode'][0..1] == 'VO'
    end

    rtmp_url = good['streamer']+'mp4:'+good['url']
	if not rtmp_url then
		return error("No such quality")
	end
	log(rtmp_url, LOG_DEBUG)

	filename = $options[:filename] || vid_id+"_"+title.gsub(/[\/ "*:<>?|\\]/," ")+"_"+$options[:qual]+".flv"
	return log("Already downloaded") if File.exists?(filename)

	log("Dumping video : "+filename)
	log("rtmpdump -o #{filename} -r \"#{rtmp_url}\"", LOG_DEBUG)
	fork do 
		exec("rtmpdump", "-q", "-o", filename, "-r", rtmp_url)
	end

	Process.wait
	if $?.exited?
		case $?.exitstatus
			when 0 then
				log("Video successfully dumped")
			when 1 then
				return error("rtmpdump failed")
			when 2 then
				log("rtmpdump exited, trying to resume")
				exec("rtmpdump", "-e", "-q", "-o", "#{vid_id}.flv", "-r", rtmp_url)
		end
	end
end

begin 
	OptionParser.new do |opts|
		opts.on("--quiet") { |v| $options[:log] = LOG_QUIET }
		opts.on('-v', "--verbose") { |v| $options[:log] = LOG_DEBUG }
		opts.on('-b', "--best [NUM]") { |n| $options[:best] = n ? n.to_i : 10 }
		opts.on('-t', "--top [NUM]") { |n| $options[:top] = (n ? n.to_i : 10) }
		opts.on("-l", "--lang=LANG_ID") {|l| $options[:lang] = l }
		opts.on("-q", "--qual=QUAL") {|q| $options[:qual] = q }
		opts.on("-o", "--output=filename") {|f| $options[:filename] = f }
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

$hc = HttpClient.new("www.arte.tv")
$hc.allowbadget = true

progs_data = get_progs_urls(progname)
log(progs_data, LOG_DEBUG)
progs_data.each {|p| dump_video(p[0], p[1], p[2]) }
