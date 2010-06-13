#!/usr/bin/ruby
require 'libhttpclient'

class Spider < HttpClient
	def get(url, timeout=nil, recursive=false)
		return if recursive
		if $stdout.tty?
			print " fetch #{@http_s.host}#{url} (#@referer)          \r"
			$stdout.flush
		end
		super
	end
end

class Web
	def initialize
		# hostname => Spider
		@spiders = {}
		# hostname => [[url, referer, path], ...]
		@to_get = {}
		# hostname => { url => true }
		@got = {}
		
		@hostswhitelist = [/iiens\.net$/]
	end

	def save
	end
	
	def load
	end
	
	def crawl(url)
		raise 'invalid url' if url !~ /^http:\/\/([^\/]+)(\/.*)/
		sv, file = $1, $2
		fetch sv, file, 'http://www.google.com/', '/'

		until @to_get.empty?
			@to_get.keys.each { |srv|
				url = @to_get[srv].shift
				if not url
					@to_get.delete srv
				else
					begin
						fetch(srv, *url)
					rescue
						puts "Error #{$!.class} #{$!.message} for #{srv}#{url[0]}"
					end
				end
			}
		end
		puts '                                       '
	end

	def fetch(srv, url, ref, pat)
		unless s = @spiders[srv]
			s = @spiders[srv] = Spider.new(srv)
			s.allowbadget = true
		end

		s.path.replace pat
		@got[srv] ||= {}
		url = s.abs_path url
		return if @got[srv][url]
		@got[srv][url] = true
		if url.count('/') > 20
			puts "Error path too deep for #{srv}#{url}       "
			return
		end
		s.referer = ref
		s.links.clear if s.links
		s.get url, 0.6
		
		s.links.compact.each { |l|
			l.sub!(/#.*/, '')
			case l
			when '', /^mailto:/, /^javascript:/
				next
			when %r{^https://}
				puts "not going to #{l} from #{srv} #{url}"
				next
			when %r{^http://([^/]*)(/.*)?}
				sv, l = $1, $2
				l ||= '/'
				next unless @hostswhitelist.find { |hw| sv =~ hw }
			else
				sv = srv
			end
			(@to_get[sv] ||= []) << [l, s.referer.dup, s.path.dup]
		} if s.links
	end
end

Web.new.crawl ARGV.shift
