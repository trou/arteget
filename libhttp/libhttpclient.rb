#
# librairie emulant un client http
#
# par Yoann Guillot - 2004
# fixes by Flyoc (surtout des bug reports en fait !) (merci quand meme.)
# yay, un patch <area>
# support proxy socks
#

require 'libhttp'
require 'libhtml'
require 'thread'

# full emulation of http client (js ?)

class HttpClientBadGet < RuntimeError
end
class HttpClientBadPost < RuntimeError
end

class HttpClient
	def self.bgthreadcount ; @@bgthreadcount ||= 4 ; end
	def self.bgthreadcount=(c) ; @@bgthreadcount = c ; end

	attr_accessor :path, :cookie, :get_url_allowed, :post_allowed, :cache, :cur_url, :curpage, :history, :links, :http_s
	attr_accessor :bogus_site, :referer, :allowbadget, :do_cache, :othersite_redirect, :bgdlqueue, :bgdlthreads

	def self.open(*a)
		s = new(*a)
		yield s
	ensure
		s.close if s
	end

	def initialize(url)
		if not url.include? '://'
			url = "http://#{url}/"
		end
		if ENV['http_proxy'] =~ /^http:\/\/(.*?)\/?$/
			url = "http-proxy://#$1/#{url}"
		elsif ENV['http_proxy'] =~ /^socks:\/\/(.*?)\/?$/
			url = "socks://#$1/#{url}"
		end
		@http_s = HttpServer.new(url)
		@bogus_site = false
		@allowbadget = false
		@next_fetch = Time.now
		@do_cache = true
		@othersite_redirect = lambda { |url_, recurs| puts "Will no go to another site ! (#{url_})" if not recurs rescue nil }
		@bgdlqueue = Queue.new
		@bgdlthreads = Array.new(self.class.bgthreadcount) { Thread.new {
			Thread.current[:status] = :idle
			Thread.current[:http_s] = HttpServer.new(url)
			loop {
				tg = @bgdlqueue.shift
				if tg == :close
					Thread.current[:http_s].close
					break
				end
				Thread.current[:status] = :busy
				get(tg, 0, {}, true)
				Thread.current[:status] = :idle
			}
		} }
		clear
	end

	def urlpath; @http_s.urlpath ; end

	def close
		clear
		@http_s.close
		@bgdlthreads.each { @bgdlqueue << :close }
		@bgdlthreads.each { |t| t.join }
	rescue
	end

	undef http_s
	def http_s
		Thread.current[:http_s] || @http_s
	end

	def wait_bg
		sleep 0.1 until @bgdlqueue.empty? and @bgdlthreads.all? { |t| t[:status] == :idle }
	end

	def status_save
		[@path, @get_url_allowed, @post_allowed, @referer, @curpage, @cur_url].map { |o| o.dup rescue o }
	end

	def status_restore(s)
		 @path, @get_url_allowed, @post_allowed, @referer, @curpage, @cur_url = *(s.map { |o| o.dup rescue o })
	end
	
	def loadcookies(f)
		File.readlines(f).each { |l|
			c = l.chomp.split(/\s*=\s*/, 2)
			@cookie[c[0]] = c[1]
		}
	end

	def savecookies(f)
		File.open(f, 'w') { |fd|
			@cookie.each { |k, v| fd.puts "#{k} = #{v}" }
		}
	end

	def clear
		@post_allowed = Array.new
		@get_url_allowed = Array.new
		@history = Array.new
		@cache = Hash.new
		@cookie = Hash.new
		@referer = ''
		@path = '/'
		@cur_url = nil
		@curpage = nil
	end
	
	def inval_cur
		@cur_url = nil
		@curpage = nil
	end
	
	def sess_headers
		h = Hash.new
		if not @cookie.empty?
			h['Cookie'] = @cookie.map { |k, v| "#{k}=#{v}" if not ['path', 'domain', 'expires'].include?(k.downcase) }.compact.join('; ')
		end
		if @referer and not @referer.empty?
			h['Referer'] = @referer
		end
		h
	end

	def cururlprefix
		"http#{'s' if @http_s.use_ssl}://#{@http_s.vhost}#{":#{@http_s.vport}" if @http_s.vport != (@http_s.use_ssl ? 443 : 80)}"
	end

	def cururlprefix_re
		re = Regexp.escape(cururlprefix)
		if @http_s.vport == (@http_s.use_ssl ? 443 : 80)
			re << "(?::#{@http_s.vport})?"
		end
		re
	end

	def abs_url(url)
		return url if url.include? '://'
		cururlprefix + abs_path(url)
	end

	def abs_path(url, update_class = false)
		path = @path.clone
		url = $1 if url =~ /^#{cururlprefix_re}(\/.*)/
		if (url =~ /^(\/(?:[^?]+\/)?)(.*?)$/)
			# /, /url, /url/url, /url/url?url/url
			path = $1
			page = $2
		elsif (url =~ /^([^?]+\/)(.*?)$/)
			# url/url, url/url?url/url
			relpath = $1
			page = $2

			# handle ../
			while relpath[0..2] == '../'
				path.sub!(/\/[^\/]+\/$/, '/')
				relpath = relpath[3..-1]
			end
			
			# skip ./
			while relpath[0..1] == './'
				relpath = relpath[2..-1]
			end
			
			path += relpath
		else
			# url, url?url/url
			page = url.dup
		end
		
		page.sub!(/#[^?]*/, '')
		if (page == '..')
			page = ''
			path.sub!(/\/[^\/]+\/$/, '/')
		end
		
		@path = path if update_class
		return path+page
	end

	def fetch_next_now
		@next_fetch = Time.now
	end
	
	def head(url, timeout=nil, headers={})
		url = url.sub(/^#{cururlprefix_re}\//, '/')
		return if url =~ /^https?:\/\//
		url.gsub!(' ', '%20')
		url = abs_path(url, false)
		return @curpage if url == @cur_url
		http_s.head(url, sess_headers.merge(headers))
	end

	def get(url, timeout=nil, headers={}, recursive=false)
		url = url.sub(/^#{cururlprefix_re}\//, '/')
		return @othersite_redirect[url, recursive] if url =~ /^https?:\/\//

		url.gsub!(' ', '%20')
		return if recursive and @cache[url]

		url = abs_path(url, (not recursive))

		return @curpage if url == @cur_url
		
		if not @allowbadget and not recursive and not @get_url_allowed.empty? and not @get_url_allowed.include?(url.sub(/\?.*$/, ''))
			puts "Forbidden to get #{url} from here ! We are at #{@cur_url}, allowed list: #{@get_url_allowed.sort.join(', ')}" rescue nil
			raise HttpClientBadGet.new(url)
		end
		
		if not recursive
			@history << url
			diff = @next_fetch.to_f - Time.now.to_f
			sleep diff if diff > 0
			timeout ||= 1
				
			@next_fetch = Time.now + timeout
			@cur_url = url
		end

		page = http_s.get(url, sess_headers.merge(headers))
		page = analyse_page(url, page, recursive)

		@curpage = page if not recursive
		
		return page
	end

	def post_raw(url, postdata, headers={}, timeout=nil)
		url = url.sub(/^#{cururlprefix_re}\//, '/')
		raise "no post_raw crossdomain: #{cururlprefix} -> #{url}" if url =~ /^https?:\/\//

		url = abs_path(url, true)
		
		diff = @next_fetch.to_i - Time.now.to_i
		sleep diff if diff > 0
		timeout ||= 1
		@next_fetch = Time.now + timeout

		@cur_url = url
		@history << 'postraw:'+url
		page = http_s.post_raw(url, postdata, sess_headers.merge(headers))
		page = analyse_page(url, page)
		@curpage = page
		
		return page
	end

	def post(url, postdata, timeout=nil, pretimeout=nil)
		url = url.sub(/^#{cururlprefix_re}\//, '/')
		raise "no post crossdomain: #{cururlprefix} -> #{url}" if url =~ /^https?:\/\//

		url = abs_path(url, true)
		
		allow = @cur_url ? false : true
		@post_allowed.each { |p|
			if p.url.sub(/^#{cururlprefix_re}/, '') == url and p.method == 'post'
				allow = true
				p.verify(postdata)
			end
		}
		if not @allowbadget and not allow
			puts "Form action unknown here ! cur: #{@cur_url}, action: #{url}" rescue nil
			raise HttpClientBadPost.new(url)
		end
		
		
		pretimeout ||= 1
		diff = @next_fetch.to_i - Time.now.to_i + pretimeout
		sleep diff if diff > 0
		timeout ||= 1
		@next_fetch = Time.now + timeout

		do_post(url, postdata)
	end

	def do_post(url, postdata)
		@cur_url = url
		@history << 'post:'+url
		page = http_s.post(url, postdata, sess_headers)
		page = analyse_page(url, page)
		@curpage = page
		
		return page
	end

	# TODO need a rewrite
	def analyse_page(url, page, recursive=false)
		raise RuntimeError.new('No page... Timed out ?') if not page
		if (page.headers['set-cookie'])
			page.headers['set-cookie'].split(/\s*;\s*/).each { |c|
				if c =~ /^([^=]*)=(.*)$/
					name, val = $1, $2
					if (val == 'deleted')
						@cookie.delete(name)
					else
						@cookie[name] = val
					end
				end
			}
		end
		
		case page.status
		when 301, 302
			newurl = page.headers['location'].sub(/#[^?]*/, '')
			puts "#{page.status} to #{newurl}" if $DEBUG and not recursive
			case newurl
			when /^http#{'s' if @http_s.use_ssl}:\/\/#{@http_s.vhost}(?::#{@http_s.vport or @http_s.use_ssl ? 443 : 80})?(.*)$/, /^(\/.*)$/
				newurl = $1
				newurl = '/'+newurl if newurl[0] != ?/
				if newurl =~ /^(.*?)\?(.*)$/
					newurl, gdata = $1, $2
					newurl += '?' +
					gdata #.split('&').map{ |e| e.split('=', 2).map{ |k| HttpServer.urlenc(k) }.join('=') }.join('&')
				end
				@get_url_allowed << newurl.sub(/[?#].*$/, '') if not recursive
				return get(newurl, 0, {}, recursive)
			when /^https?:\/\//
				#@referer = 'http://' + @http_s.vhost + url	# XXX curpage url or original referer ?
				return @othersite_redirect[newurl, recursive]
			else
				raise RuntimeError.new("No location for 302 at #{url}!!!") if not newurl
				newurl = abs_path(newurl)
				@get_url_allowed << newurl.sub(/[?#].*$/, '') if not recursive
				return get(newurl, 0, {}, recursive)
			end
		when 401, 403, 404
			puts "Error #{page.status} with url #{url} from #{@referer}" if not @bogus_site rescue nil
			@cache[url] = page
			return page
		when 200
			# noreturn
		else
			puts "Error code #{page.status} with #{url} from #{@referer} :\n#{page}" rescue nil
			return page
		end
			
		@cache[url] = (@do_cache ? page : ((@cache[url] and @cache[url] != '') ? page : ''))
		
		return page if recursive or (page.headers['content-type'] and page.headers['content-type'] !~ /text\/(ht|x)ml/)
		
		@referer ||= ''
		@referer.replace 'http://' + @http_s.vhost + url
		
		@get_url_allowed.clear
		@get_url_allowed << url.sub(/[#?].*$/, '')
		@post_allowed.clear

		get_allow = Array.new
		to_fetch = Array.new
		page.parse = parsehtml(page.content)
		
		postform = nil
		page.parse.each { |e|
			case e.type
			when 'img', 'Script'
				to_fetch << e['src']
			when 'frame', 'iframe'
				get_allow << e['src']
			when 'a', 'area'
				get_allow << e['href']
			when 'link'
				to_fetch << e['href'] unless e['rel'] == 'alternate'
			when 'form'
				# default target
				tg = cururlprefix + url.sub(/[?#].*$/, '')
				if e['action'] and e['action'].length > 0
					if e['action'][0] == ??
						tg = tg.sub(/^.*\//, '') + e['action']
					else
						tg = e['action']
					end
					tg = cururlprefix + abs_path(tg) if tg !~ /^https?:\/\// #or tg =~ /^#{cururlprefix_re}\//
				end
				postform = PostForm.new tg unless postform and postform.url == tg
				if e['method'] and e['method'].downcase == 'post'
					postform.method = 'post'
				else
					postform.method = 'get'
					get_allow << tg.sub(/^#{cururlprefix_re}/, '')
				end
			when '/form'
				if postform
					@post_allowed << postform
					postform = nil
				end
			end
			
			postform.sync_elem(e) if postform
			
			to_fetch << e['background'] if e['background']
		}
		@post_allowed << postform if postform

		@links = (to_fetch + get_allow).compact.uniq unless recursive
		
		to_fetch_temp = Array.new
		to_fetch.each { |u|
			u.strip! if u
			case u
			when '', nil
			when /^(https?:\/\/[^\/]*)?(\/[^?]*)(?:\?(.*))?/i
				if $3
					to_fetch_temp << ($1.to_s + HttpServer.urlenc($2) + '?' + $3)
				else
					to_fetch_temp << ($1.to_s + HttpServer.urlenc($2))
				end
			when /^(mailto|magnet):/i, /^javascript/i, /\);?$/
			else
				if u =~ /([^?]*)\?(.*)/
					u = HttpServer.urlenc(abs_path($1)) + '?' + $2
				else
					u = HttpServer.urlenc(abs_path(u))
				end
				to_fetch_temp << u
				puts "Debug: to_fetch add catchall #{u.inspect}" if u !~ /^[a-zA-Z0-9._\/?=&;#%!-]*$/ and not @cache.has_key?(u) and not @bogus_site rescue nil
			end
		}
		
		to_fetch = to_fetch_temp.uniq
#puts "for #{url}: recursing to #{to_fetch.sort.inspect}"
		to_fetch.each { |u| @bgdlqueue << u if not @bgdlthreads.empty? }
		wait_bg
		
		get_allow.each { |u|
			u.strip! if u
			case u
			when /^#{cururlprefix_re}(\/[^?#]*)/i
				@get_url_allowed << $1
			when /^(\/[^?#]*)/
				@get_url_allowed << $1
			when nil
			when /^(https?|irc):\/\//i, /^(mailto|magnet):/i, /^javascript/i, /\);?$/
			else
				if u.length > 0
					nu = abs_path(u).sub(/[?#].*$/, '')
					@get_url_allowed << nu
				end
				puts "Debug: get_allow add catchall #{u.inspect}" if u !~ /^[a-zA-Z0-9._\/=?&;#%!-]*$/ and not @bogus_site rescue nil
			end
		}

		@get_url_allowed.uniq!
		@post_allowed.uniq!
		
		return page
	end
	
	def to_s
		"Http Client for #{cururlprefix}: current url #{@cur_url}\n"+
		"Cookies: #{@cookie.inspect}\n"+
		"Cache: #{@cache.keys.sort.join(', ')}\n"+
		"Get allowed: #{@get_url_allowed.sort.join(', ')}\n"+
		"post allowed:\n#{@post_allowed.join("\n")}"
	end

	def inspect
		"#<HttpClient: site=#{@http_s.host.inspect}, @cur_url=#{@cur_url.inspect}>"
	end
end

class PostForm
	attr_accessor :url, :vars, :mandatory, :method
	
	# vars is a hash, key = name of each var for the form,
	#   value = 'blabla' if var has default value (for input and textarea)
	#   value = ['bla', 'blo', 'bli'] for <select><option>, [0] = default value
	#   value = nil if no default value (or if <select> empty)
	
	def initialize(url)
		@url = url
		@vars = Hash.new
		@mandatory = Hash.new
		@textarea_name = nil
		@opt_vars = nil
	end

	def eql?(other)
		return false unless @url.eql?(other.url)
		@mandatory.each_key { |k|
			return false unless other.mandatory.has_key?(k)
			return false unless @mandatory[k].eql?(other.mandatory[k])
		}
		other.mandatory.each_key { |k| return false unless @mandatory.has_key?(k) }
		return true
	end

	def hash
		h = @url.hash
		@mandatory.each_key { |k| h += @mandatory[k].hash }
		return h
	end

	def sync_elem(e)
		case e.type
		when 'input'
			e['type'] ||= 'text'
			if e['name']
				if e['type'].downcase == 'radio'
					(@vars[e['name']] ||= []) << e['value']
				else
					(@opt_vars ||= []) << e['name'] if e['type'].downcase == 'checkbox'
					@vars[e['name']] = e['value'] || ''
					@mandatory[e['name']] = e['value'] if e['value'] and e['type'] and e['type'].downcase == 'hidden' and e['name'] !~ /\[\]/
				end
			elsif e['type'].downcase == 'image'
				@vars['x'] = rand(15).to_s
				@vars['y'] = rand(10).to_s
			end
		
		when 'textarea'
			@textarea_name = e['name']
		when '/textarea'
			if @textarea_name
				@vars[@textarea_name] = ''
				@textarea_name = nil
			end
		
		when 'select'
			@select_name = e['name']
			@vars[@select_name] = [] if @select_name
		when '/select'
			if @select_name and @vars[@select_name].empty?
				@vars[@select_name] = nil
			end
			@select_name = nil	
		when 'option'
			if @select_name and e['value']
				@vars[@select_name] << e['value']
			end
		
		when 'String'
			if @textarea_name
				@vars[@textarea_name] = e['content']
				@textarea_name = nil
			end
		end
	end

	def verify(postdata, debug=false)
		@mandatory.each_key { |k|
			if @mandatory[k] != postdata[k]
				puts "verif postdata: mandatory var #{k.inspect} set to #{postdata[k].inspect}, should be #{@mandatory[k].inspect}" if $DEBUG rescue nil
				return false
			end
		}
		
		postdata.each_key { |k|
			if not @vars.has_key?(k)
				puts "Postdata check: posting unknown variable #{k.inspect}" if $DEBUG rescue nil
				return false
			end
		}
		
		@vars.each_key { |k|
			if not postdata[k] # var not submitted: check for a default value
				if not @vars[k]
					puts "Postdata check: unfilled varname #{k.inspect} - no default" if $DEBUG rescue nil
					return false
				else
					dval = @vars[k]
					postdata[k] = dval unless @opt_vars.to_a.include? k
					puts "Postdata check: set default value '#{dval.inspect}' for #{k.inspect}" if $DEBUG rescue nil
				end
			end
			postdata[k] = postdata[k].first if postdata[k].kind_of? ::Array
		}
		
		return true
	end
	
	def to_s
		"PostForm: url #{@url} ; vars: #{@vars.inspect} (mandatory: #{@mandatory.keys.inspect})"
	end
end

# sync multiple httpclient for multiple (v)hosts
# they share cookies
class HttpClientMulti
	attr_accessor :http_list, :current, :domain
	def initialize(domain='.foo.com')
		@domain = domain
		@http_list = {}
	end

	def url_get_host(url)
		# http://foo != https://foo
		$1 if url =~ /^(https?:\/\/[^\/:]+)/i
	end

	def new_http(host, url)
		h = HttpClient.new(url)
		h.othersite_redirect = lambda { |u, r|
			newhost = url_get_host(u)
			if newhost[-@domain.length, @domain.length] == @domain
				get(u, nil, {}, r)
			else
				puts "redirect out of domain: #{u}"
			end
		}
		ref = @http_list.values.first
		h.cookie = ref.cookie if ref
		# proxy, l/p ?
		@http_list[host] = h
	end

	def set_http(url)
		if host = url_get_host(url)
			r = @current.referer if current
			srv = @http_list[host] || new_http(host, url)
			srv.referer = r if r
			srv
		else
			@current	# relative url
		end
	end

	def get(url, *a)
		srv = set_http(url)
		@current = srv if not a.last == true	# recursive
		srv.get(url, *a)
		#@current.curpage
	end

	def post(url, *a)
		@current = set_http(url)
		@current.post(url, *a)
		#@current.curpage
	end

	def method_missing(*a)
		@current.send(*a)
	end
end
