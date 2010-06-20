#!/usr/bin/env ruby
# arteget 2010/06/13
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
require 'uri'
require 'libhttpclient'
require 'rexml/document'
include REXML

# language for videos
LANG="fr"
QUALITY="hd"

LOG_QUIET = 0
LOG_NORMAL = 1
LOG_DEBUG = 2

$loglevel = LOG_NORMAL

def fatal(msg)
	puts msg
	exit(1)
end

def log(msg, level=LOG_NORMAL)
	puts msg if level <= $loglevel
end

progname=ARGV.shift
fatal("Program name needed") if not progname

hc = HttpClient.new("videos.arte.tv")
hc.allowbadget = true

log("Getting index")

index = hc.get('/fr/videos/arte7').content
index_list_url = index[/listViewUrl: "(.*)"/,1]
log(index_list_url, LOG_DEBUG)
fatal("Cannot find index list") if not index_list_url 

log("Getting list page")
index_list = hc.get(index_list_url).content
programme = index_list[/href="(.*\/#{progname}.*\.html)"/,1]

if not programme then
	log("Could not find program in list, trying another way")
	log("Getting program page")
	programme = index[/href="(.*\/#{progname}.*\.html)"/,1]
	fatal("Could not find program page") if not programme
	prog_page = hc.get(programme).content
	prog_list_url = prog_page[/listViewUrl: "(.*)"/,1]
	fatal("Cannot find list for program") if not prog_list_url

	log("Getting list page")
	prog_list = hc.get(prog_list_url).content
	programme = prog_list[/href="(.*\.html)"/,1]

end

fatal("Cannot find program at all") if not programme
vid_id = programme[/-(.*)\./,1]
fatal("No video id in URL") if not vid_id
fatal("Already downloaded") if Dir["*#{vid_id}*"].length > 0 

log("Getting video page")
page_video = hc.get(programme).content
videoref_url = page_video[/videorefFileUrl = "http:\/\/videos.arte.tv(.*\.xml)"/,1]
player_url = page_video[/url_player = "(.*\.swf)"/,1]
log(videoref_url, LOG_DEBUG) 
log(player_url, LOG_DEBUG) 

log("Getting video XML desc")
videoref_content = hc.get(videoref_url).content
log(videoref_content, LOG_DEBUG)
ref_xml = Document.new(videoref_content)
vid_lang_url = ref_xml.root.elements["videos/video[@lang='#{LANG}']"].attributes['ref']
vid_lang_url.gsub!(/.*arte.tv/,'')
log(vid_lang_url, LOG_DEBUG)

log("Getting #{LANG} #{QUALITY} video XML desc")
vid_lang_xml_url = hc.get(vid_lang_url).content
vid_lang_xml = Document.new(vid_lang_xml_url)
rtmp_url = vid_lang_xml.root.elements["urls/url[@quality='#{QUALITY}']"].text
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

