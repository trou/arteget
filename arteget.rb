#!/usr/bin/env ruby
# arteget
# Copyright 2008-2022 Raphaël Rigo
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
require 'open-uri'

LOG_ERROR = -1
LOG_QUIET = 0
LOG_NORMAL = 1
LOG_DEBUG = 2
LOG_DEBUG2 = 3

$options = {:log => LOG_NORMAL, :lang => "fr", :qual => "xq", :variant => nil,
            :desc => false, :num => 1, :min => 0}

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

def log(msg, level=LOG_NORMAL, pp=false)
    if pp then
      pp msg if level <= $options[:log]
    else
      puts msg if level <= $options[:log]
    end
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

# Basically gets the lists of programs in JSON format
# returns an array of arrays, containing 2 strings : [video_id, title]
def get_videos(lang, progname, num)
    progs = find_prog(progname)

    if progs and progs.has_key?('url') then
        url = progs['url']
        id = progs['programId']
    else
        fatal("Cannot find requested program(s)")
    end
    teasers = []

    # Trying first the collections URL
    page = 1
    while teasers.length < num do
      collec_url = "https://www.arte.tv/api/rproxy/emac/v4/#{$options[:lang]}/web/data/COLLECTION_VIDEOS/?collectionId=#{id}&page=#{page}"
      log("Getting #{progname} (page #{page}) JSON collection at #{collec_url}")
      prog_coll = Net::HTTP.get_response(URI(collec_url))
      log("JSON collection HTTP code: #{prog_coll.code}", LOG_DEBUG)
      if prog_coll.code == '200' then
        log(prog_coll.body, LOG_DEBUG2)
        coll_parsed = JSON.parse(prog_coll.body)
        if coll_parsed['tag'] == "Ok" then
          coll_parsed = coll_parsed['value']
        else
          fatal("Server returned an error")
        end
        if coll_parsed['datakey']['id'] == 'COLLECTION_VIDEOS' then
          teasers += coll_parsed['data'].find_all {|e| e['type'] == "teaser" and e['duration'] > $options[:min]}
          # Stop looping if there's no new video
          num = teasers.length if coll_parsed['data'].length == 0
          page += 1
        end
      end
    end

    if teasers.length == 0 then
      # Get JSON for program in the HTML page
      log("Getting #{progname} page at #{url}")
      prog_page = Net::HTTP.get(URI(url))
      prog_json = prog_page[/window.__INITIAL_STATE__ = (.*);/, 1]
      prog_keys = ->(j) { j.dig('pages', 'list') }
      unless prog_json then
        prog_json = prog_page[%r{<script id="__NEXT_DATA__" type="application/json">([^<]+)</script>}, 1]
        prog_keys = ->(j) { j.dig('props', 'pageProps') }
      end
      log(prog_json, LOG_DEBUG2)
      log("Program id: "+id)
      begin
        prog_list = prog_keys.call(JSON.parse(prog_json))
      rescue TypeError
        fatal("Error: could not parse program JSON")
      end
      if prog_list.has_key?(id+'_{}') then
        key = id+'_{}'
      else
        key = prog_list.keys.find { |key| key =~ /#{id}/ }
        # Search one level deeper, for example: initialPage[id="RC-020692_fr_web"]/zones
        key ||= prog_list.select { |_, value| value.is_a?(Hash) && value.key?('zones') }.keys.first

        log("Program id #{prog_list[key]['id']} doesn't match #{id}", LOG_DEBUG) unless prog_list[key]['id'] =~ /#{id}/
        fatal("Error: could not find program info") unless key
      end

      prog_parsed = prog_list[key]['zones']

      list = prog_parsed.find {|p| p['code']['name'] == 'collection_videos'}
      # Maybe it's a program, not a collection
      if not list then
          log('No collection found, trying program')
          list = prog_parsed.find {|p| p['code']['name'] == 'program_content'}
          if not list then
              fatal("Could not find program")
          end
          type = "program"
      else
          type = "teaser"
      end

      # Maybe it's a collection with subcollection
      if list['data'].empty? then
        collections = prog_parsed.find_all {|p| p['code']['name'] == 'collection_subcollection'}
        list['data'] = collections.map{|e| e['data']}.flatten(1)
      end

      teasers = list['data'].find_all {|e| e['type'] == type}
    end

    # Sort by ID as date is no more present
    # XXX maybe we should not sort ?
    log(teasers.map {|e| e['programId']}.sort.reverse, LOG_DEBUG)
    prog_res = teasers.sort_by {|e| e['programId']}.reverse[0..num-1]
    videos = prog_res.map { |cur| {:title => cur['title'], :id => cur['programId']}}
    return videos
end

# Parse HLS m3u to extract audio and video urls
def parse_m3u(m3u_url)
    m3u = fetch(m3u_url)
    # TODO: actually handle quality
    vid_p_url = m3u.lines.find {|l| l.include?("v1080.m3u8")}.rstrip()
    m3u.lines.find {|l| l =~ /TYPE=AUDIO.*URI="(.*m3u8)"/}.rstrip()
    aud_p_url = $1
    log("aud_p_url: "+aud_p_url, LOG_DEBUG)
    fetch(aud_p_url).lines.find {|l| l =~ /#EXT-X-MAP:URI="(.*?)"/}
    aud_file = $1
    aud_url = aud_p_url[/.*\//]+aud_file
    log("vid_p_url: "+vid_p_url, LOG_DEBUG)
    fetch(vid_p_url).lines.find {|l| l =~ /#EXT-X-MAP:URI="(.*?)"/}
    vid_file = $1
    vid_url = vid_p_url[/.*\//]+vid_file
    return vid_url, aud_url
end

def display_variants(vid_json_data)
    streams = vid_json_data['attributes']['streams']
    log(streams, LOG_DEBUG)
    variants = streams.reduce([]) {
        |result,h|
        # TODO: handle multiple versions
        variant = [h['versions'][0]['eStat']['ml5'], h['versions'][0]['label']]
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

def do_wget(url, filename)
    log("wget -nv -O \"#{filename}\" \"#{url}\"", LOG_DEBUG)
    fork do
        exec("wget", "-nv", "-O", filename, url)
    end

    Process.wait
    if $?.exited?
        case $?.exitstatus
            when 0 then
                log("File successfully dumped")
            when 1 then
                return error("wget failed")
            when 2 then
                log("wget exited, trying to resume")
                exec("wget", "-c", "-O", filename, wget_url)
        end
    end
end

def dump_video(vidinfo)
    log("Trying to get #{vidinfo[:title] || vidinfo[:id]}")

    log("Getting video description JSON")
    videoconf = "https://api.arte.tv/api/player/v2/config/#{$options[:lang]}/#{vidinfo[:id]}"
    log(videoconf, LOG_DEBUG)

    videoconf_content = fetch(videoconf)
    if videoconf_content =~ /(plus|pas) disponible/ then
        videoconf = "https://api.arte.tv/api/player/v2/config/#{$options[:lang]}/#{vidinfo[:id].gsub(/-A$/,"-F")}"
        videoconf_content = fetch(videoconf)
    end
    log(videoconf_content, LOG_DEBUG2)
    vid_json = JSON.parse(videoconf_content)

    if videoconf_content =~ /type": "error"/
        puts "An error happened : "+vid_json["videoJsonPlayer"]["custom_msg"]["msg"]
        Kernel.exit(1)
    end

    if $options[:variant] == 'list' then
        display_variants(vid_json['data'])
        exit
    end

    log(vid_json['data'], LOG_DEBUG2)
    log("vid_json['data']['attributes']['metadata']", LOG_DEBUG2)
    log(vid_json['data']['attributes']['metadata'], LOG_DEBUG2)
    metadata = vid_json['data']['attributes']['metadata']
    # Fill metadata if needed
    title = metadata['title'] || ""
    teaser = metadata['description'] + ""
    log(title+" : "+teaser)

    ## Get Playlist with all streams
    pl_url = vid_json['data']['attributes']["streams"].first['url']
    log(pl_url, LOG_DEBUG)
    pl = fetch(pl_url)
    log(pl, LOG_DEBUG2)

    streams = vid_json['data']['attributes']["streams"]
    log("streams (#{streams.class})", LOG_DEBUG2)
    log(streams, LOG_DEBUG2, true)

    if $options[:variant] then
        good = streams.find_all do |h|
            h['mainQuality']['code'] =~ /^#{$options[:qual]}/i and
            $options[:variant] == h['versions'][0]['eStat']['ml5']
        end
    end
    log("good", LOG_DEBUG2)
    log(good, LOG_DEBUG2)

    # If we failed to find specified variant, try normal
    if not good or good.length == 0 then
        if $options[:variant] then
            log("Variant not found ? Trying default")
        end
        good = streams.find_all do |v|
            v['mainQuality']['code'] =~ /^#{$options[:qual]}/i and
            v['protocol'] == 'API_HLS_NG' and
            v['slot'].to_i == 1
        end
    end

    log("good2", LOG_DEBUG2)
    log(good, LOG_DEBUG2)
    if good.length > 1 then
        log("Several version matching, downloading the first one")
    end
    good = good.first

    playlist_url = good['url']
    if not playlist_url then
        return error("No such quality")
    end
    log("playlist_url", LOG_DEBUG)
    log(playlist_url, LOG_DEBUG)

    vid_url, aud_url = parse_m3u(playlist_url)

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

    log("Dumping video")
    do_wget(vid_url, filename+"-video.mp4")
    log("Dumping audio")
    do_wget(aud_url, filename+"-audio.mp4")

    log("Merging files")
    fork do
        exec("ffmpeg", "-v", "8", "-i", filename+"-video.mp4", "-i", filename+"-audio.mp4", "-c:v", "copy", "-c:a", "copy",  filename)
    end

    Process.wait
    if $?.exited?
        case $?.exitstatus
            when 0 then
                log("File successfully dumped")
            when 1 then
                return error("wget failed")
            when 2 then
                log("wget exited, trying to resume")
                exec("wget", "-c", "-O", filename, wget_url)
        end
    end
    File.unlink(filename+"-video.mp4")
    File.unlink(filename+"-audio.mp4")
end

def find_prog(prog)
    prog_enc = CGI::escape(prog)
    search_url = "https://www.arte.tv/api/rproxy/emac/v4/#{$options[:lang]}/web/pages/SEARCH/?query=#{prog_enc}"
    log("Searching for #{prog} at #{search_url}")

    plus7 = Net::HTTP.get(URI("#{search_url}"))
    results = JSON.parse(plus7)

    log(results, LOG_DEBUG2)

    return results['value']['zones'][0]['content']['data'][0]
end

QUALITY = ['sq', 'eq', 'mq', 'xq']

parser = OptionParser.new do |opts|
    opts.banner = 'Usage : arteget [-v] [--qual=QUALITY] [--lang=LANG] [-n=NUM] program|URL'
    opts.separator ''
    opts.separator '    URL: download the video on this page'
    opts.separator '    program: download the latest available broadcasts of "program"'
    opts.separator ''

    opts.on("--quiet", 'only error output') { |v| $options[:log] = LOG_QUIET }
    opts.on("--variant=VARIANT",
            "try do download specified version (e.g. 'VF-STF', 'VA-STA', 'VO-STF'), " \
            "'list' display available values and exit.") {
        |v| $options[:variant] = v
    }
    opts.on('-D', "--description", 'save description along with the file') { |v| $options[:desc] = true }
    opts.on('-v', "--verbose", 'debug output') { |v| $options[:log] = LOG_DEBUG }
    opts.on('-V', "--veryverbose", 'debug2 output') { |v| $options[:log] = LOG_DEBUG2 }
    opts.on('-m', "--min-dur=m", 'minimum duration (seconds)') { |m| $options[:min] = m.to_i }
    opts.on('-f', "--force", 'overwrite destination file') { $options[:force] = true }
    opts.on("-l", "--lang=LANG", 'choose language, german (de) or french (fr) (default is "fr")') { |l| $options[:lang] = l }
    opts.on("-q", "--qual=QUAL", QUALITY, 'choose quality, sq is default', '(%s)' % QUALITY.join(', ')) { |q| $options[:qual] = q }
    opts.on("-o", "--output=filename", 'filename if downloading only one program') { |f| $options[:filename] = f }
    opts.on("-n", "--num=N", "download N programs") { |n| $options[:num] = n }
    opts.on("-d", "--dest=directory") do |d|
        if not File.directory?(d)
            puts "Destination is not a directory"
            exit 1
        end
        $options[:dest] = d
    end
end

begin parser.parse!
rescue OptionParser::ParseError
    puts $!
    puts parser
    exit
end

if ARGV.length == 0
    puts parser
    exit
elsif ARGV.length == 1
    progname=ARGV.shift
end

if not which("wget")
    puts "wget not found"
    exit 1
end

case progname
    when /^https:/
        log("Trying with URL")
        vid_id = progname[/([0-9]{6}-[0-9]{3}(-[AF])?)/,1]
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
