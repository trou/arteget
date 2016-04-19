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

$options = {:log => LOG_NORMAL, :lang => "fr", :qual => "sq", :subs => false, :desc => false}


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

def which(cmd)
  exts = ENV['PATHEXT'] ? ENV['PATHEXT'].split(';') : ['']
  ENV['PATH'].split(File::PATH_SEPARATOR).each do |path|
    exts.each { |ext|
      exe = File.join(path, "#{cmd}#{ext}")
      return exe if File.executable? exe
    }
  end
  return nil
end

def print_usage
	puts "Usage : arteget [-v] [--qual=QUALITY] [--lang=LANG] --best[=NUM]|--top[=NUM]|URL|program"
	puts "\t\t--quiet\t\t\tonly error output"
	puts "\t-v\t--verbose\t\tdebug output"
	puts "\t-f\t--force\t\t\toverwrite destination file"
	puts "\t-o\t--output=filename\t\t\tfilename if downloading only one program"
	puts "\t-d\t--dest=directory\t\t\tdestination directory"
	puts "\t-D\t--description\t\t\tsave description along with the file"
	puts "\t\t--subs\t\t\ttry do download subtitled version"
	puts "\t-q\t--qual=sq|eq|mq\tchoose quality, sq is default"
	puts "\t-l\t--lang=fr|de\t\tchoose language, german or french (default)"
	puts "\t-b\t--best [NUM]\t\tdownload the NUM (10 default) best rated programs"
	puts "\t-t\t--top [NUM]\t\tdownload the NUM (10 default) most viewed programs"
	puts "\tURL\t\t\t\tdownload the video on this page"
	puts "\tprogram\t\t\t\tdownload the latest available broadcasts of \"program\", use \"list\" to list available program names."
end

# Find videos in the given JSON array
def parse_json(progs)
	result = progs.map { |p| [p['url'], p['title'], p['desc']] }
	return result
end

# Basically gets the lists of programs in JSON format
# returns an array of arrays, containing 2 strings : [video_id, title]
def get_progs_ids(progname)
    progs = get_progs_json()

    #TODO : fix
	if $options[:best] then
		bestnum = $options[:best]
		log("Computing best #{bestnum}")
        ranked = vids.find_all { |v| v["video_rank"] != nil and v["video_rank"]  > 0 }
        ranked.sort! { |a, b| a["video_rank"] <=> b["video_rank"] }.reverse!
        pp ranked
        result = parse_json(ranked[0,bestnum])
	elsif $options[:top] then
		topnum = $options[:top]
		log("Computing top #{topnum}")
        vids.sort! { |a, b| a["video_views"][/^[0-9 ]+/].gsub(' ','').to_i <=> b["video_views"][/^[0-9 ]+/].gsub(' ', '').to_i }.reverse!
        result = parse_json(vids[0,topnum])
	else
        # We have a program name
        progs = progs.find_all {|p| p["title"].casecmp(progname) == 0 }
        if progs != nil and progs.length > 0 then
		    p = progs.first['permalink']
            if not p =~ /www.arte.tv/ then
                fatal("Not on main arte site, won't work :(")
            end
            prog_c = HttpClient.new(p)
            prog_content = prog_c.get(p).content
            log(prog_content, LOG_DEBUG)
            article = prog_content.lines.find {|l| l =~ /article.*about=.*has-video/}
	        log(article, LOG_DEBUG) 
            url = article[/about="\/.*?-([0-9]+-[0-9]+)"/,1]
            if not url then
                vid = prog_content.lines.find {|l| l =~ /arte_vp_url/}
                url = vid[/\/fr\/([0-9]+-[0-9]+)-/,1]
            end
            log("Vid ID"+url, LOG_DEBUG)
            result = [[url, progname]]
        end
	end
	fatal("Cannot find requested program(s)") if result == nil or result.length == 0
	return result
end

def dump_video(video_id, title, teaser)
    if title == "" and teaser == "" then
        log("Trying to get #{video_id}")
    else
        log("Trying to get #{title}")
    end
    if video_id =~ /:\/\// then
        # ugly but the only way (?)
        pp video_id
        vid_id = video_id[/([0-9]{6}-[0-9]{3})/,1]
        if not vid_id then
            page = $hc.get(video_id).content
            vid = page.lines.find {|l| l =~ /arte_vp_url/}
            log(vid, LOG_DEBUG)
            vid_id = vid[/\/fr\/([0-9]+-[0-9]+)-/,1]
        end
        return error("No video id in URL") if not vid_id
    else
        vid_id = video_id
    end

    pp vid_id
	log("Getting video description JSON")
    videoconf = "/api/player/v1/config/fr/#{vid_id}-A?vector=ARTETV"
	log("https://api.arte.tv/"+videoconf, LOG_DEBUG) 

	videoconf_content = $hc.get(videoconf).content
    if videoconf_content =~ /plus disponible/ then
        videoconf = "/api/player/v1/config/fr/#{vid_id}-F?vector=ARTETV"
        videoconf_content = $hc.get(videoconf).content
    end
	log(videoconf_content, LOG_DEBUG)
	vid_json = JSON.parse(videoconf_content)

    # Fill metadata if needed
    if title == "" or teaser == "" or not teaser or not title then
        title = title || vid_json['videoJsonPlayer']['VTI'] || ""
        teaser = vid_json['videoJsonPlayer']['V7T'] || vid_json['videoJsonPlayer']['VDE'] || ""
        log(title+" : "+teaser)
    end

    ###
    # Some information :
    #   - mediaType can be "mp4" or "hls" 
    #   - versionProg can be '1' for native, '2' for the other langage and '8' for subbed
    ###
    good = vid_json['videoJsonPlayer']["VSR"].values.find_all do |v|
        v['quality'] =~ /^#{$options[:qual]}/i and
        v['mediaType'] == 'mp4' and
        (v['versionProg'].to_i == ($options[:subs] ? 8 : 1) or
         v['versionProg'].to_i == ($options[:subs] ? 3 : 1))
    end

    # If we failed to find a subbed version, try normal
    if not good or good.length == 0 and $options[:subs] then 
        log("No subbed version ? Trying normal")
        good = vid_json['videoJsonPlayer']["VSR"].values.find_all do |v|
            v['quality'] =~ /^#{$options[:qual]}/i and
            v['mediaType'] == 'mp4' and
            v['versionProg'].to_i == 1
        end
    end
    if good.length > 1 then
        log("Several version matching, downloading the first one")
    end
    good = good.first
    
    wget_url = good['url']
	if not wget_url then
		return error("No such quality")
	end
	log(wget_url, LOG_DEBUG)

    if $options[:dest] then
        filename = $options[:dest]+File::SEPARATOR
    else
        filename = ""
    end
	filename = filename + ($options[:filename] || vid_id+"_"+title.gsub(/[\/ "*:<>?|\\]/," ")+"_"+$options[:qual]+".mp4")
	return log("Already downloaded") if File.exists?(filename) and not $options[:force]

    if $options[:desc] then
        log("Dumping description : "+filename+".txt")
        d = File.open(filename+".txt", "wt")
        d.write(Time.now().to_s+"\n")
        d.write(title+"\n"+teaser+"\n");
        d.close()
    end

	log("Dumping video : "+filename)
	log("wget -O #{filename} \"#{wget_url}\"", LOG_DEBUG)
	fork do 
		exec("wget", "-O", filename, wget_url)
	end

	Process.wait
	if $?.exited?
		case $?.exitstatus
			when 0 then
				log("Video successfully dumped")
			when 1 then
				return error("wget failed")
			when 2 then
				log("wget exited, trying to resume")
                exec("wget", "-c", "-O", filename, wget_url)
		end
	end
end

def get_progs_json()
	log("Getting index")

    log("/guide/#{$options[:lang]}/plus7/", LOG_DEBUG)

	plus7 = $hc.get("/guide/#{$options[:lang]}/plus7/").content
    progs = plus7.lines.find {|a| a=~/clusters:/}.gsub('clusters:','')

	fatal("Cannot get program list JSON") if not progs

    progs = JSON.parse(progs)
    return progs
end

def list_progs()
    progs = get_progs_json()
    progs.map! { |v| v["title"] }
    progs.sort!.uniq!
    puts "Available program titles : "
    puts progs.join("\n")
end

begin 
	OptionParser.new do |opts|
		opts.on("--quiet") { |v| $options[:log] = LOG_QUIET }
		opts.on("--subs") {$options[:subs] = true }
		opts.on('-D', "--description") { |v| $options[:desc] = true }
		opts.on('-v', "--verbose") { |v| $options[:log] = LOG_DEBUG }
		opts.on('-f', "--force") { $options[:force] = true }
		opts.on('-b', "--best [NUM]") { |n| $options[:best] = n ? n.to_i : 10 }
		opts.on('-t', "--top [NUM]") { |n| $options[:top] = (n ? n.to_i : 10) }
		opts.on("-l", "--lang=LANG_ID") {|l| $options[:lang] = l }
		opts.on("-q", "--qual=QUAL") {|q| $options[:qual] = q }
		opts.on("-o", "--output=filename") {|f| $options[:filename] = f }
		opts.on("-d", "--dest=directory")  do |d|
            if not File.directory?(d)
                puts "Destination is not a directory"
                exit 1
            end
            $options[:dest] = d
        end
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

if not which("rtmpdump")
    puts "rtmpdump not found"
    exit 1
end

$hc = HttpClient.new("www.arte.tv")
$hc.allowbadget = true

$api = HttpClient.new("https://api.arte.tv/")
$api.allowbadget = false

case progname
    when /^http:/
        log("Trying with URL")
        progs_data = [[progname, "", ""]]
    when "list"
        list_progs
        exit(0)
    else
        progs_data = get_progs_ids(progname)
    end

puts "Dumping #{progs_data.length} program(s)"
log(progs_data, LOG_DEBUG)
progs_data.each {|p| dump_video(p[0], p[1], p[2]) }
