#
# librairie HTTP bas niveau
#
# par Yoann Guillot - 2004
#

require 'socket'
require 'timeout'
require 'zlib'
begin
require 'openssl'
rescue LoadError
end

class HttpResp
	attr_accessor :answer, :headers, :content_raw
	def initialize
		@answer = String.new
		@headers = Hash.new
		@content_raw = String.new
		@content = nil
		@parse = nil
	end

	attr_writer :parse
	def parse(type=nil)
		type ? @parse.find_all { |e| e.type == type } : @parse
	end
	
	def status
		$1.to_i if @answer =~ /^HTTP\/1.\d+ (\d+) /
	end

	def content
		if not @content
			if @headers['content-encoding'] == 'gzip'
				tmpname = '/tmp/httpget.gz.'
				ext = rand(10000)
				ext = rand(10000) while (File.exist?(tmpname+ext.to_s))
				begin
					File.open(tmpname+ext.to_s, 'wb+') { |file|
						file.write(@content_raw)
						file.rewind
						zfile = Zlib::GzipReader.new(file)
						@content = zfile.read
						zfile.close
					}
				rescue IOError
					# some version of zfile.close will also close file and make File.open {} raise
				ensure
					File.unlink(tmpname+ext.to_s)
				end
			elsif @headers['content-encoding'] == 'deflate'
				puts "Content-encoding deflate !!!"
				@content = Zlib::Inflate.inflate(@content_raw)
			else
				@content = @content_raw
			end
			@content_raw = nil
		end
		@content
	end

	def each_table
	
		raise "No parse" unless @parse

		# table est un array de [tablenum, ligne, col]
		# [[2, 1, 1], [1, 2, 3]] indique que l'on est dans la case [2, 3] de la premiere table contenue dans 
		# la case [1, 1] de la deuxieme table du toplevel
		# <table>..</table> <table><tr><td> <table><tr></tr><tr><td></td><td></td><td> ->*<-
		
		table = []
		donetable = false
		
		@parse.each { |e|
			case e.type
			when 'table'
				# est-ce que l'on suit une autre table ou non
				if donetable
					donetable = false
					table.last[0] += 1
					table.last[1] = table.last[2] = 0
				else
					table << [1, 0, 0]
				end
			
			when 'tr'
				table.last[1] += 1
				table.last[2] = 0
			
			when 'td', 'th'
				if donetable
					table.pop
					donetable = false
				end
				table.last[2] += 1

			# not mandatory
			when '/td', '/th'
			when '/tr'
			
			when '/table'
				table.pop if donetable
				donetable = true
			
			else
				donetable = table.pop if donetable

				# cannot distinguish A and B in "A<table></table>B"

				yield table, e

				if donetable
					table << donetable
					donetable = true
				end
			end
		}
		
		nil
	end
	
	def to_s
		@answer + @headers.map { |k, v| "#{k}: #{v}" }.join("\r\n") + "\r\n\r\n" + content
	end

	def inspect
		'<#HttpAnswer:' + {'answer' => answer, 'headers' => headers, 'content' => content}.inspect
	end

	def get_text_sep; @get_text_sep ||= ' ' end
	def get_text_sep=(a) @get_text_sep = a end

	def get_text(onlyform=false, onlystr=true)
		inform = false
		inbody = false
		innoframes = false
		maynl = false
		txt = []
		nl = "\n"
		@parse ||= parsehtml content
		@parse.each { |e|
			case e.type
			when 'body';  inbody = true ; next
			when '/body'; inbody = false
			when 'noframes';  innoframes = true
			when '/noframes'; innoframes = false ; next
			when 'form';  inform = true
			when '/form'
				txt << e << nl unless onlystr
				inform = false
			end
			next if (onlyform and not inform) or not inbody or innoframes

			case e.type
			when 'String'
				txt << get_text_sep if maynl
				txt << HttpServer.htmlentitiesdec(e['content'].gsub(/(?:&nbsp;|\s)+/, ' ').strip)
				maynl = true
			when 'optgroup'
				txt << nl if maynl
				txt << HttpServer.htmlentitiesdec(e['label'])
				txt << nl
				maynl = false
				
			when 'b', '/b', 'td', '/td', 'span', '/span', 'font', '/font', 'Comment', 'Script', 'img', 'em', '/em'
				nil
		
			when 'br', 'p', '/p', 'table', '/table', 'tr', '/tr', 'tbody', '/tbody', 'div', '/div', '/option', 'li', '/li', 'ul', '/ul'
				txt << nl if maynl
				maynl = false
			
			else
			# input select option textarea
				next if onlystr
				txt << nl if maynl
				maynl = false
				txt << e << nl
			end
		}
		txt.join
	end
end

class HttpServer
	attr_accessor :host, :port, :vhost, :vport, :loginpass, :proxyh, :proxyp, :proxylp, :use_ssl, :socket

	# global defaults
	@@timeout = 120
	@@hdr_useragent = 'Mozilla/5.0 (Windows; U; Windows NT 5.1; en-US; rv:1.8.1) Gecko/20061010 Firefox/2.0'
	@@hdr_accept = 'text/xml,application/xml,application/xhtml+xml,text/html;q=0.9,text/plain;q=0.8,image/png,*/*;q=0.5'
	@@hdr_encoding = 'gzip,deflate'
	@@hdr_language = 'en'
	class << self
		%w[timeout hdr_useragent hdr_accept hdr_encoding hdr_language].each { |a|
			define_method(a) { class_variable_get "@@#{a}" }
			define_method(a+'=') { |v| class_variable_set "@@#{a}", v }
		}
	end
	attr_accessor :timeout, :hdr_useragent, :hdr_accept, :hdr_encoding, :hdr_language

	def self.open(*a)
		s = new(*a)
		yield s
	ensure
		s.close
	end

        def initialize(url)
		if not url.include? '://'
			url = "http://#{url}/"
		end

		hostre = '[\w.-]+|\[[a-fA-F0-9:]+\]'
                raise "Unparsed url #{url.inspect}" unless md = %r{^(?:(http-proxy|socks)://(\w*:\w*@)?(#{hostre})(:\d+)?/)?http(s)?://(\w*:\w*@)?(?:([\w.-]+)(:\d+)?@)?(#{hostre})(:\d+)?/}.match(url)

		@proxytype, @proxylp, @proxyh, proxyp, @use_ssl, @loginpass, vhost, vport, @host, port = md.captures
		@proxyh = @proxyh[1..-2] if @proxyh and @proxyh[0] == ?[
		@host   = @host[1..-2]   if @host[0] == ?[

                @proxyp = proxyp ? proxyp[1..-1].to_i : 3128
                @port = port ? port[1..-1].to_i : (@use_ssl ? 443 : 80)

                @proxylp = 'Basic '+[@proxylp.chop].pack('m').chomp if @proxylp
		@loginpass = nil if @loginpass == ':@'
                @loginpass = 'Basic '+[@loginpass.chop].pack('m').chomp if @loginpass
                @vhost = vhost ? vhost : @host
		@vport = vport ? vport[1..-1].to_i : @port

                @socket = nil

		@timeout = @@timeout

		@hdr_useragent = @@hdr_useragent
		@hdr_accept    = @@hdr_accept
		@hdr_encoding  = @@hdr_encoding
		@hdr_language  = @@hdr_language
	end

	def self.urlenc(s)
		s.to_s.gsub(/([^a-zA-Z0-9_.\/ -]+)/n) do
			'%' + $1.unpack('H2' * $1.size).join('%').upcase
		end.tr(' ', '+')
	end

	def self.get_form_url(url, vars)
		vars.empty? ? url : (
			url + '?' + vars.map { |k, v|
				"#{urlenc k}=#{urlenc(htmlentitiesdec(v.to_s))}"
			}.join('&')
		)
	end

	# This takes the long string til EOE, matches it with scan, and build a hash from that
	# > 255 omitted
	HTMLENTITIES = Hash[*<<EOE.scan(/ENTITY (\S+)\s+CDATA "&#(\d+);"/).map { |k, v| [k, v.to_i] }.flatten] if not defined? HTMLENTITIES
<!ENTITY quot    CDATA "&#34;"   -- quotation mark = APL quote, U+0022 ISOnum -->
<!ENTITY amp     CDATA "&#38;"   -- ampersand, U+0026 ISOnum -->
<!ENTITY lt      CDATA "&#60;"   -- less-than sign, U+003C ISOnum -->
<!ENTITY gt      CDATA "&#62;"   -- greater-than sign, U+003E ISOnum -->

<!ENTITY nbsp   CDATA "&#160;" -- no-break space = non-breaking space, U+00A0 ISOnum -->
<!ENTITY iexcl  CDATA "&#161;" -- inverted exclamation mark, U+00A1 ISOnum -->
<!ENTITY cent   CDATA "&#162;" -- cent sign, U+00A2 ISOnum -->
<!ENTITY pound  CDATA "&#163;" -- pound sign, U+00A3 ISOnum -->
<!ENTITY curren CDATA "&#164;" -- currency sign, U+00A4 ISOnum -->
<!ENTITY yen    CDATA "&#165;" -- yen sign = yuan sign, U+00A5 ISOnum -->
<!ENTITY brvbar CDATA "&#166;" -- broken bar = broken vertical bar, U+00A6 ISOnum -->
<!ENTITY sect   CDATA "&#167;" -- section sign, U+00A7 ISOnum -->
<!ENTITY uml    CDATA "&#168;" -- diaeresis = spacing diaeresis, U+00A8 ISOdia -->
<!ENTITY copy   CDATA "&#169;" -- copyright sign, U+00A9 ISOnum -->
<!ENTITY ordf   CDATA "&#170;" -- feminine ordinal indicator, U+00AA ISOnum -->
<!ENTITY laquo  CDATA "&#171;" -- left-pointing double angle quotation mark = left pointing guillemet, U+00AB ISOnum -->
<!ENTITY not    CDATA "&#172;" -- not sign, U+00AC ISOnum -->
<!ENTITY shy    CDATA "&#173;" -- soft hyphen = discretionary hyphen, U+00AD ISOnum -->
<!ENTITY reg    CDATA "&#174;" -- registered sign = registered trade mark sign, U+00AE ISOnum -->
<!ENTITY macr   CDATA "&#175;" -- macron = spacing macron = overline = APL overbar, U+00AF ISOdia -->
<!ENTITY deg    CDATA "&#176;" -- degree sign, U+00B0 ISOnum -->
<!ENTITY plusmn CDATA "&#177;" -- plus-minus sign = plus-or-minus sign, U+00B1 ISOnum -->
<!ENTITY sup2   CDATA "&#178;" -- superscript two = superscript digit two = squared, U+00B2 ISOnum -->
<!ENTITY sup3   CDATA "&#179;" -- superscript three = superscript digit three = cubed, U+00B3 ISOnum -->
<!ENTITY acute  CDATA "&#180;" -- acute accent = spacing acute, U+00B4 ISOdia -->
<!ENTITY micro  CDATA "&#181;" -- micro sign, U+00B5 ISOnum -->
<!ENTITY para   CDATA "&#182;" -- pilcrow sign = paragraph sign, U+00B6 ISOnum -->
<!ENTITY middot CDATA "&#183;" -- middle dot = Georgian comma = Greek middle dot, U+00B7 ISOnum -->
<!ENTITY cedil  CDATA "&#184;" -- cedilla = spacing cedilla, U+00B8 ISOdia -->
<!ENTITY sup1   CDATA "&#185;" -- superscript one = superscript digit one, U+00B9 ISOnum -->
<!ENTITY ordm   CDATA "&#186;" -- masculine ordinal indicator, U+00BA ISOnum -->
<!ENTITY raquo  CDATA "&#187;" -- right-pointing double angle quotation mark = right pointing guillemet, U+00BB ISOnum -->
<!ENTITY frac14 CDATA "&#188;" -- vulgar fraction one quarter = fraction one quarter, U+00BC ISOnum -->
<!ENTITY frac12 CDATA "&#189;" -- vulgar fraction one half = fraction one half, U+00BD ISOnum -->
<!ENTITY frac34 CDATA "&#190;" -- vulgar fraction three quarters = fraction three quarters, U+00BE ISOnum -->
<!ENTITY iquest CDATA "&#191;" -- inverted question mark = turned question mark, U+00BF ISOnum -->
<!ENTITY Agrave CDATA "&#192;" -- latin capital letter A with grave = latin capital letter A grave, U+00C0 ISOlat1 -->
<!ENTITY Aacute CDATA "&#193;" -- latin capital letter A with acute, U+00C1 ISOlat1 -->
<!ENTITY Acirc  CDATA "&#194;" -- latin capital letter A with circumflex, U+00C2 ISOlat1 -->
<!ENTITY Atilde CDATA "&#195;" -- latin capital letter A with tilde, U+00C3 ISOlat1 -->
<!ENTITY Auml   CDATA "&#196;" -- latin capital letter A with diaeresis, U+00C4 ISOlat1 -->
<!ENTITY Aring  CDATA "&#197;" -- latin capital letter A with ring above = latin capital letter A ring, U+00C5 ISOlat1 -->
<!ENTITY AElig  CDATA "&#198;" -- latin capital letter AE = latin capital ligature AE, U+00C6 ISOlat1 -->
<!ENTITY Ccedil CDATA "&#199;" -- latin capital letter C with cedilla, U+00C7 ISOlat1 -->
<!ENTITY Egrave CDATA "&#200;" -- latin capital letter E with grave, U+00C8 ISOlat1 -->
<!ENTITY Eacute CDATA "&#201;" -- latin capital letter E with acute, U+00C9 ISOlat1 -->
<!ENTITY Ecirc  CDATA "&#202;" -- latin capital letter E with circumflex, U+00CA ISOlat1 -->
<!ENTITY Euml   CDATA "&#203;" -- latin capital letter E with diaeresis, U+00CB ISOlat1 -->
<!ENTITY Igrave CDATA "&#204;" -- latin capital letter I with grave, U+00CC ISOlat1 -->
<!ENTITY Iacute CDATA "&#205;" -- latin capital letter I with acute, U+00CD ISOlat1 -->
<!ENTITY Icirc  CDATA "&#206;" -- latin capital letter I with circumflex, U+00CE ISOlat1 -->
<!ENTITY Iuml   CDATA "&#207;" -- latin capital letter I with diaeresis, U+00CF ISOlat1 -->
<!ENTITY ETH    CDATA "&#208;" -- latin capital letter ETH, U+00D0 ISOlat1 -->
<!ENTITY Ntilde CDATA "&#209;" -- latin capital letter N with tilde, U+00D1 ISOlat1 -->
<!ENTITY Ograve CDATA "&#210;" -- latin capital letter O with grave, U+00D2 ISOlat1 -->
<!ENTITY Oacute CDATA "&#211;" -- latin capital letter O with acute, U+00D3 ISOlat1 -->
<!ENTITY Ocirc  CDATA "&#212;" -- latin capital letter O with circumflex, U+00D4 ISOlat1 -->
<!ENTITY Otilde CDATA "&#213;" -- latin capital letter O with tilde, U+00D5 ISOlat1 -->
<!ENTITY Ouml   CDATA "&#214;" -- latin capital letter O with diaeresis, U+00D6 ISOlat1 -->
<!ENTITY times  CDATA "&#215;" -- multiplication sign, U+00D7 ISOnum -->
<!ENTITY Oslash CDATA "&#216;" -- latin capital letter O with stroke = latin capital letter O slash, U+00D8 ISOlat1 -->
<!ENTITY Ugrave CDATA "&#217;" -- latin capital letter U with grave, U+00D9 ISOlat1 -->
<!ENTITY Uacute CDATA "&#218;" -- latin capital letter U with acute, U+00DA ISOlat1 -->
<!ENTITY Ucirc  CDATA "&#219;" -- latin capital letter U with circumflex, U+00DB ISOlat1 -->
<!ENTITY Uuml   CDATA "&#220;" -- latin capital letter U with diaeresis, U+00DC ISOlat1 -->
<!ENTITY Yacute CDATA "&#221;" -- latin capital letter Y with acute, U+00DD ISOlat1 -->
<!ENTITY THORN  CDATA "&#222;" -- latin capital letter THORN, U+00DE ISOlat1 -->
<!ENTITY szlig  CDATA "&#223;" -- latin small letter sharp s = ess-zed, U+00DF ISOlat1 -->
<!ENTITY agrave CDATA "&#224;" -- latin small letter a with grave = latin small letter a grave, U+00E0 ISOlat1 -->
<!ENTITY aacute CDATA "&#225;" -- latin small letter a with acute, U+00E1 ISOlat1 -->
<!ENTITY acirc  CDATA "&#226;" -- latin small letter a with circumflex, U+00E2 ISOlat1 -->
<!ENTITY atilde CDATA "&#227;" -- latin small letter a with tilde, U+00E3 ISOlat1 -->
<!ENTITY auml   CDATA "&#228;" -- latin small letter a with diaeresis, U+00E4 ISOlat1 -->
<!ENTITY aring  CDATA "&#229;" -- latin small letter a with ring above = latin small letter a ring, U+00E5 ISOlat1 -->
<!ENTITY aelig  CDATA "&#230;" -- latin small letter ae = latin small ligature ae, U+00E6 ISOlat1 -->
<!ENTITY ccedil CDATA "&#231;" -- latin small letter c with cedilla, U+00E7 ISOlat1 -->
<!ENTITY egrave CDATA "&#232;" -- latin small letter e with grave, U+00E8 ISOlat1 -->
<!ENTITY eacute CDATA "&#233;" -- latin small letter e with acute, U+00E9 ISOlat1 -->
<!ENTITY ecirc  CDATA "&#234;" -- latin small letter e with circumflex, U+00EA ISOlat1 -->
<!ENTITY euml   CDATA "&#235;" -- latin small letter e with diaeresis, U+00EB ISOlat1 -->
<!ENTITY igrave CDATA "&#236;" -- latin small letter i with grave, U+00EC ISOlat1 -->
<!ENTITY iacute CDATA "&#237;" -- latin small letter i with acute, U+00ED ISOlat1 -->
<!ENTITY icirc  CDATA "&#238;" -- latin small letter i with circumflex, U+00EE ISOlat1 -->
<!ENTITY iuml   CDATA "&#239;" -- latin small letter i with diaeresis, U+00EF ISOlat1 -->
<!ENTITY eth    CDATA "&#240;" -- latin small letter eth, U+00F0 ISOlat1 -->
<!ENTITY ntilde CDATA "&#241;" -- latin small letter n with tilde, U+00F1 ISOlat1 -->
<!ENTITY ograve CDATA "&#242;" -- latin small letter o with grave, U+00F2 ISOlat1 -->
<!ENTITY oacute CDATA "&#243;" -- latin small letter o with acute, U+00F3 ISOlat1 -->
<!ENTITY ocirc  CDATA "&#244;" -- latin small letter o with circumflex, U+00F4 ISOlat1 -->
<!ENTITY otilde CDATA "&#245;" -- latin small letter o with tilde, U+00F5 ISOlat1 -->
<!ENTITY ouml   CDATA "&#246;" -- latin small letter o with diaeresis, U+00F6 ISOlat1 -->
<!ENTITY divide CDATA "&#247;" -- division sign, U+00F7 ISOnum -->
<!ENTITY oslash CDATA "&#248;" -- latin small letter o with stroke, = latin small letter o slash, U+00F8 ISOlat1 -->
<!ENTITY ugrave CDATA "&#249;" -- latin small letter u with grave, U+00F9 ISOlat1 -->
<!ENTITY uacute CDATA "&#250;" -- latin small letter u with acute, U+00FA ISOlat1 -->
<!ENTITY ucirc  CDATA "&#251;" -- latin small letter u with circumflex, U+00FB ISOlat1 -->
<!ENTITY uuml   CDATA "&#252;" -- latin small letter u with diaeresis, U+00FC ISOlat1 -->
<!ENTITY yacute CDATA "&#253;" -- latin small letter y with acute, U+00FD ISOlat1 -->
<!ENTITY thorn  CDATA "&#254;" -- latin small letter thorn, U+00FE ISOlat1 -->
<!ENTITY yuml   CDATA "&#255;" -- latin small letter y with diaeresis, U+00FF ISOlat1 -->
<!ENTITY hellip CDATA "&#46;" -- ellipse, ..., manually added -->
<!ENTITY apos   CDATA "&#39;"  -- apostrophe, ..., manual -->
EOE
	def self.htmlentitiesdec(s)
		s.gsub(/&#(x?\d+);/) {
			v = (($1[0] == ?x) ? $1[1..-1].to_i(16) : $1.to_i)
			(v < 256) ? v.chr : $&
		}.gsub(/&(\w+);/) { HTMLENTITIES[$1] ? HTMLENTITIES[$1].chr : $& }
	end

	def self.htmlentitiesenc(s)
		s.gsub(/(.)/) {
			e = HTMLENTITIES.index $1[0]
			e = nil if e == 'hellip'
			e ? "&#{e};" : $1
		}
	end
	
	def setup_request_headers(headers)
		headers['Host'] = @vhost
		headers['Host'] += ":#@vport" if @vport != 80
		headers['User-Agent'] ||= @hdr_useragent
		headers['Accept'] ||= @hdr_accept
		headers['Connection'] ||= 'keep-alive'
		headers['Keep-Alive'] ||= 300
		headers['Accept-Charset'] ||= 'ISO-8859-1,utf-8;q=0.7,*;q=0.7'
		headers['Accept-Encoding'] ||= @hdr_encoding
		headers['Accept-Language'] ||= @hdr_language
		headers['Authorization'] ||= @loginpass if @loginpass
		headers['Proxy-Authorization'] ||= @proxylp if @proxylp and not @use_ssl
	end

	def head(page, headers = Hash.new)
		setup_request_headers(headers)
		
		# sort headers (TODO better)
		h = headers.dup
		h = ["Host: #{h.delete 'Host'}"] +
			h.map { |k, v| "#{k}: #{v}" }
		req = ["HEAD #{'http://' << (@host + (@port != 80 ? ":#@port" : '')) if @proxyh}#{page} HTTP/1.1"] + h
		req = req.join("\r\n") + "\r\n\r\n"
		read_resp send_req(req), true
	rescue Errno::ECONNREFUSED
		resp = HttpResp.new
		resp.answer.replace("HTTP/1.1 503 Connection refused")
		resp.content_raw << "The server refused the connection"
		return resp
	end

	def get(page, headers = Hash.new)
		setup_request_headers(headers)
		
		# sort headers (TODO better)
		h = headers.dup
		h = ["Host: #{h.delete 'Host'}"] +
			h.map { |k, v| "#{k}: #{v}" }
		req = ["GET #{'http://' << (@host + (@port != 80 ? ":#@port" : '')) if @proxyh}#{page} HTTP/1.1"] + h
		req = req.join("\r\n") + "\r\n\r\n"
		read_resp send_req(req)
	rescue Errno::ECONNREFUSED
		resp = HttpResp.new
		resp.answer.replace("HTTP/1.1 503 Connection refused")
		resp.content_raw << "The server refused the connection"
		return resp
	end

	def post_raw(page, postraw, headers = Hash.new)
		setup_request_headers(headers)
		headers['Content-type'] ||= 'application/octet-stream'
		headers['Content-length'] = postraw.length
		req = ["POST #{'http://' << (@host + (@port != 80 ? ":#@port" : '')) if @proxyh}#{page} HTTP/1.1"] + headers.map { |k, v| "#{k}: #{v}" }
		req = req.join("\r\n") + "\r\n\r\n" + postraw
		
		read_resp send_req(req)
	rescue Errno::ECONNREFUSED
		resp = HttpResp.new
		resp.answer.replace("HTTP/1.1 503 Connection refused")
		resp.content_raw << "The server refused the connection"
		return resp
	end

	def post(page, postdata, headers = Hash.new)
		headers['Content-type'] ||= 'application/x-www-form-urlencoded'

		post_raw(page, postdata.map { |k, v|
			# a => [a1, a2], b => b1   =>   'a=a1&a=a2&b=b1'
			((v.kind_of? Array) ? v : [v]).map { |vi| "#{HttpServer.urlenc k}=#{HttpServer.urlenc vi}" }.join('&')
		}.join('&'), headers)
	end

        def connect_socket
		case @proxytype
		when 'http-proxy'
                        @socket = TCPSocket.new @proxyh, @proxyp
                        if @use_ssl
				rq =  "CONNECT #@host:#@port HTTP/1.1\r\n"
				rq << "Proxy-Authorization: #{@proxylp}\r\n" if @proxylp
				rq << "\r\n"
				@socket.write rq
                                buf = @socket.gets
                                raise "non http answer #{buf[1..100].inspect}" if buf !~ /^HTTP\/1.. (\d+) /
                                raise "CONNECT bad response: #{buf.inspect}" if $1.to_i != 200
                                nil until @socket.gets.chomp.empty?
                        end
		when 'socks'
                        @socket = TCPSocket.new @proxyh, @proxyp
			# socks_ver 1=connect/2=bind port dest/0.0.0.1=sock4adns creds_strz hostsocks4a_strz
			buf = [4, 1, @port, 1, '', @host].pack('CCnNa*xa*x')
			@socket.write buf
			bufa = @socket.read 8
			resp = %w[access_granted access_failed failed_noident failed_badindent][bufa[1] - ?Z]
			raise "socks: #{resp} #{bufa.inspect}" if resp != 'access_granted'
		else
                        @socket = TCPSocket.new @host, @port
		end
                if @use_ssl
                        @socket = OpenSSL::SSL::SSLSocket.new(@socket, OpenSSL::SSL::SSLContext.new)
                        @socket.sync_close = true
                        @socket.connect
                end
        end

	def close
		return if not @socket
 		@socket.shutdown
		@socket.close
		@socket = nil
	rescue
	end

	def send_req(req)
		s = nil
		retried = 0
		puts 'send_req:', req if $DEBUG
	begin
		if not @socket or !( @socket.write req ; s = @socket.gets )
			close

			connect_socket

			@socket.write req
			s = @socket.gets
		end
	rescue Errno::EPIPE, Errno::ECONNRESET, IOError
		raise if retried > 2
		retried += 1
		@socket = nil
		retry
	end
		return s
	end

	def read_resp(status, no_body=false)
		page = HttpResp.new
		page.answer.replace(status||'')
		close_sock = true
		Timeout.timeout(@timeout, RuntimeError) {
			# parse le header renvoyé par le serveur
			while line = @socket.gets
				if line =~ /^([^:]*):\s*(.*?)\r?$/
					k, v = $1.downcase, $2
					if (page.headers[k])
						page.headers[k] += '; '+v
					else
						page.headers[k] = v
					end
				end
				break if line =~ /^\r?$/
			end
			if no_body
			elsif page.headers['content-length']
				contentlength = page.headers['content-length'].to_i
				while contentlength > 1024
					page.content_raw << @socket.read(1024)
					contentlength -= 1024
				end
				page.content_raw << @socket.read(contentlength) if contentlength > 0
				close_sock = false
			elsif page.headers['transfer-encoding'] == 'chunked'
				chunksize = 1
				while chunksize > 0
					line = @socket.gets
					chunksize = line.hex
					chunk = @socket.read chunksize
					page.content_raw << chunk
					@socket.read 2
				end
				close_sock = false
			else
				# Sinon on lit tout ce qu'on peut
				while not @socket.eof?
					page.content_raw << @socket.read(1024)
				end
			end
		} rescue nil
		
		close if close_sock or page.headers['connection'] == 'close'
		return page
	end
end
