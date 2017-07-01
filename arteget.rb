#!/usr/bin/env ruby
# arteget
# Copyright 2008-2017 Raphaël Rigo
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
require 'cgi'
require 'optparse'
require 'uri'
require 'json'
require 'net/http'

LOG_ERROR = -1
LOG_QUIET = 0
LOG_NORMAL = 1
LOG_DEBUG = 2

$options = {:log => LOG_NORMAL, :lang => "fr", :qual => "sq", :variant => nil, :desc => false, :num => 1}



HANDLERS = { }

def fetch(uri_str, limit = 10)
  # You should choose a better exception.
  raise ArgumentError, 'too many HTTP redirects' if limit == 0

  response = Net::HTTP.get_response(URI(uri_str))

  case response
  when Net::HTTPSuccess then
    response.body
  when Net::HTTPRedirection then
    location = response['location']
    warn "redirected to #{location}"
    fetch(location, limit - 1)
  else
    response.value
  end
end

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
	puts "Usage : arteget [-v] [--qual=QUALITY] [--lang=LANG] [-n=NUM] program|URL"
	puts "\t\t--quiet\t\t\tonly error output"
	puts "\t-v\t--verbose\t\tdebug output"
	puts "\t-f\t--force\t\t\toverwrite destination file"
	puts "\t-o\t--output=filename\t\t\tfilename if downloading only one program"
	puts "\t-D\t--description\t\t\tsave description along with the file"
	puts "\t\t--variant\t\ttry do download specified version ('VF-STF', 'VA-STA', 'VO-STF'), 'list' display available values and exit."
	puts "\t-q\t--qual=sq|eq|mq\tchoose quality, sq is default"
	puts "\t-l\t--lang=fr|de\t\tchoose language, german or french (default)"
	puts "\t-n\t--num=N\t\tdownload N programs"
	puts "\tURL\t\t\t\tdownload the video on this page"
	puts "\tprogram\t\t\t\tdownload the latest available broadcasts of \"program\"."
end


# Find videos in the given JSON array
def parse_json(progs)
	result = progs.map { |p| [p['url'], p['title'], p['desc']] }
	return result
end

# Basically gets the lists of programs in JSON format
# returns an array of arrays, containing 2 strings : [video_id, title]
def get_videos(lang, progname, num)
    progs = find_prog(progname)

    if progs.has_key?('programs') then
        prog = progs['programs'][0]
    else
        fatal("Cannot find requested program(s)") 
    end
    id = prog['id']

    # Get json for program
     
	prog_json = Net::HTTP.get("www.arte.tv","/guide/api/api/collection/#{id}/#{lang}")
    prog_res = JSON.parse(prog_json)['videos'][0..num-1]
    videos = prog_res.map { |cur| {:title => cur['title'], :id => cur['programId']}}
    return videos 
end

def display_variants(vid_json)
    variants = vid_json['videoJsonPlayer']['VSR'].values.reduce([]) {
        |result,h|
        variant = [h['versionCode'], h['versionLibelle']]
        result << variant unless result.include?(variant)
        result
    }

    format = '%7s | %s'
    if not variants.empty? then
        log(sprintf(format % ['Variant', 'Description']))
        variants.each do |v|
            log(sprintf format % v)
        end
    else
        log('Unable to find any variant')
    end
end

def dump_video(vidinfo)
    log("Trying to get #{vidinfo[:title] || vidinfo[:id]}")

	log("Getting video description JSON")
    videoconf = "https://api.arte.tv/api/player/v1/config/#{$options[:lang]}/#{vidinfo[:id]}?lifeCycle=1"
	log(videoconf, LOG_DEBUG)

	videoconf_content = fetch(videoconf)
    if videoconf_content =~ /(plus|pas) disponible/ then
        videoconf = "https://api.arte.tv/api/player/v1/config/#{$options[:lang]}/#{vidinfo[:id].gsub(/-A$/,"-F")}"
        videoconf_content = fetch(videoconf)
    end
	log(videoconf_content, LOG_DEBUG)
	vid_json = JSON.parse(videoconf_content)

    if videoconf_content =~ /type": "error"/
        puts "An error happenned : "+vid_json["videoJsonPlayer"]["custom_msg"]["msg"]
        Kernel.exit(1)
    end

    if vid_json['videoJsonPlayer']['VSR'].empty?
        log "Video found but metadata are incomplete. lang might be erroneous."
        exit
    end

    if $options[:variant] == 'list' then
        display_variants(vid_json)
        exit
    end

    # Fill metadata if needed
    title = vidinfo[:title] || vid_json['videoJsonPlayer']['VTI'] || ""
    teaser = vid_json['videoJsonPlayer']['V7T'] || vid_json['videoJsonPlayer']['VDE'] || ""
    log(title+" : "+teaser)

    ###
    # Some information :
    #   - mediaType can be "mp4" or "hls"
    #   - versionCode can be "VF-STF", "VA-STA", "VO-STF"
    #   - versionProg == 1 is the default variant (depends on lang)
    ###
    if $options[:variant] then
        good = vid_json['videoJsonPlayer']["VSR"].values.find_all do |v|
            v['quality'] =~ /^#{$options[:qual]}/i and
            v['mediaType'] == 'mp4' and
            $options[:variant] == v['versionCode']
        end
    end

    # If we failed to find specified variant, try normal
    if not good or good.length == 0 then
        if $options[:variant] then
            log("Variant not found ? Trying default")
        end
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
	filename = filename + ($options[:filename] || vidinfo[:id]+"_"+title.gsub(/[\/ "*:<>?|\\]/," ")+"_"+$options[:qual]+".mp4")
	return log("Already downloaded") if File.exists?(filename) and not $options[:force]

    if $options[:desc] then
        log("Dumping description : "+filename+".txt")
        d = File.open(filename+".txt", "wt")
        d.write(Time.now().to_s+"\n")
        d.write(title+"\n"+teaser+"\n");
        d.close()
    end

	log("Dumping video : "+filename)
	log("wget -nv -O #{filename} \"#{wget_url}\"", LOG_DEBUG)
	fork do
		exec("wget", "-nv", "-O", filename, wget_url)
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

def find_prog(prog)
	log("Searching for #{prog}")

	plus7 = Net::HTTP.get("www.arte.tv","/#{$options[:lang]}/search/?q=#{prog}")
    results = plus7.lines.find {|a| a=~/data-results=/}.gsub('data-results=','')
    results = CGI.unescapeHTML(results)

    results = results[/(\{.*\})/,1]
    log(results, LOG_DEBUG)

    results = JSON.parse(results)
    return results
end

begin
	OptionParser.new do |opts|
		opts.on("--quiet") { |v| $options[:log] = LOG_QUIET }
		opts.on("--variant=VARIANT") { |v| $options[:variant] = v }
		opts.on('-D', "--description") { |v| $options[:desc] = true }
		opts.on('-v', "--verbose") { |v| $options[:log] = LOG_DEBUG }
		opts.on('-f', "--force") { $options[:force] = true }
		opts.on("-l", "--lang=LANG_ID") {|l| $options[:lang] = l }
		opts.on("-q", "--qual=QUAL") {|q| $options[:qual] = q }
		opts.on("-o", "--output=filename") {|f| $options[:filename] = f }
		opts.on("-n", "--num=num") {|n| $options[:num] = n }
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

if ARGV.length == 0 
	print_usage
	exit
elsif ARGV.length == 1
	progname=ARGV.shift
end

if not which("rtmpdump")
    puts "rtmpdump not found"
    exit 1
end

case progname
    when /^http:/
        log("Trying with URL")
        vid_id = progname[/([0-9]{6}-[0-9]{3})/,1]
        if not vid_id then
            page = fetch(video_id)
            vid = page.lines.find {|l| l =~ /arte_vp_url/}
            log(vid, LOG_DEBUG)
            vid_id = vid[/\/#{$options[:lang]}\/([0-9]+-[0-9]+)-/,1]
        end
        fatal("No video id in URL") if not vid_id
        videos = [{:url => progname[/.*arte\.tv(\/.*)/,1], :id=>vid_id}]
    else
        videos = get_videos($options[:lang],progname, $options[:num].to_i)
end

puts "Found #{videos.length} videos" if videos.length > 1
videos.each do |video|
    log(video, LOG_DEBUG)
    dump_video(video)
    puts "\n"
end
