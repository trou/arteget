#!/usr/bin/env ruby

require 'pp'
require 'uri'
require 'libhttpclient'
require 'rexml/document'
include REXML

LOG_QUIET = 0
LOG_NORMAL = 1
LOG_DEBUG = 2

$loglevel = LOG_NORMAL

def fatal(msg)
	puts msg
	exit(1)
end

def log(msg, level)
	puts msg if level <= $loglevel
end

progname=ARGV.shift
fatal("Program name needed") if not progname

hc = HttpClient.new("videos.arte.tv")
hc.allowbadget = true

log("Getting index", LOG_NORMAL)

index = hc.get('/fr/videos/arte7').content
index_list_url = index[/listViewUrl: "(.*)"/,1]
fatal("Cannot find index list") if not index_list_url 

log("Getting list page", LOG_NORMAL)
index_list = hc.get(index_list_url).content
programme = index_list[/href="(.*\/#{progname}-.*\.html)"/,1]
#if not programme then
#	puts "No such program : #{programme}"
#	exit(1)
#end
#puts "Getting program page"
#prog_page = hc.get(programme).content
#prog_list_url = prog_page[/listViewUrl: "(.*)"/,1]
#if not prog_list_url then
#	puts "Cannot find list"
#	exit(1)
#end
#puts "Getting list page"
#prog_list = hc.get(prog_list_url).content
#first = prog_list[/href="(.*\.html)"/,1]
first = programme
fatal("Cannot find first video") if not first
vid_id = first[/-(.*)\./,1]
fatal("No video id in URL") if not vid_id

log("Getting video page", LOG_NORMAL)
page_video = hc.get(first).content
videoref_url = page_video[/videorefFileUrl = "http:\/\/videos.arte.tv(.*\.xml)"/,1]
player_url = page_video[/url_player = "(.*\.swf)"/,1]
log(videoref_url, LOG_DEBUG) 
log(player_url, LOG_DEBUG) 
log("Getting video XML desc", LOG_NORMAL)
videoref_content = hc.get(videoref_url).content
log(videoref_content, LOG_DEBUG)
ref_xml = Document.new(videoref_content)
vid_fr_url = ref_xml.root.elements["videos/video[@lang='fr']"].attributes['ref']
vid_fr_url.gsub!(/.*arte.tv/,'')
log(vid_fr_url, LOG_DEBUG)
log("Getting FR video XML desc", LOG_NORMAL)
vid_fr_xml_url = hc.get(vid_fr_url).content
vid_fr_xml = Document.new(vid_fr_xml_url)
rtmp_hd_url = vid_fr_xml.root.elements["urls/url[@quality='hd']"].text
log(rtmp_hd_url, LOG_DEBUG)

log("rtmpdump --swfVfy #{player_url} -o #{vid_id}.flv -r \"#{rtmp_hd_url}\"", LOG_NORMAL)
# ATTENTION ! FAILLE !
system("rtmpdump --swfVfy #{player_url} -o #{vid_id}.flv -r \"#{rtmp_hd_url}\"")

# Not necessary after all
#url = "doLog?securityCheck=957HOP79HSPJX&sLogId="+Time.now.to_i.to_s+"&eName=Philosophie&aCtx=VIDEOTHEK%2DPLAYER&eId="+vid_id+"&logPlay=false&dt=0&action=PLAYING&tCode="
#pp url
#th = Thread.new do
#	logid=(Time.now.to_i*1000+354).to_s
#	url = "doLog?securityCheck=957HOP79HSPJX&sLogId="+logid+"&eName=Philosophie&aCtx=VIDEOTHEK%2DPLAYER&eId="+vid_id+"&logPlay=false&dt=0&action=PLAYING&tCode="
#	cnt = 0
#	log = HttpClient.new("medialog.arte.tv",1)
#	log.get("doLog?securityCheck=957HOP79HSPJX&sLogId="+logid+"&eName=Philosophie&aCtx=VIDEOTHEK%2DPLAYER&eId="+vid_id+"&logPlay=false&dt=0&action=PLAY&tCode=0")
#	loop do
#		puts url+cnt.to_s
#		log.get(url+cnt.to_s)
#		sleep(10)
#		cnt += 10
#	end
#end
