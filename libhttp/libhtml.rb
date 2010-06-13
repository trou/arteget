# parser HTML
# par Yoann Guillot - 2004

class HtmlElement
	String = 'String'.freeze
	def self.new_string(s)
		n = new
		n.type = String
		n['content'] = s
		n
	end

	attr_accessor :type, :attr, :empty
	def initialize
		@type = nil
	end

	def [](attrname)
	       attr ? @attr[attrname] : nil	
	end

	def []=(attrname, val)
		@attr ||= {}
		@attr[attrname] = val
	end

	def to_s
		'<' << type << (attr || {}).map{ |k, v| " #{k}=\"#{v}\"" }.join << (empty ? ' />' : '>')
	end

	def ==(o)
		self.class == o.class and type == o.type and attr == o.attr and empty == o.empty
	end
	def hash
		type.hash ^ attr.hash
	end
	alias eql? ==
end

def parsehtml(page, nocache=false)
	parse = Array.new unless block_given?
	curelem = nil
	curword = ''
	curattrname = nil
	state = :waitopen
	laststate = state

	# use nocache=true to avoid this if you intend to change some of the tags
	class << parse
		def <<(e)
			# list of tags created, avoid duplicate objects (saves mem)
			@cache ||= {}
			super(@cache[e] ||= e)
		end
		# free mem used by the cache
		def done; @cache = nil end
	end if parse and not nocache

	
	# 0: waitopen		before tag/in string	''
	# 1: tagtype		in tag type		'<'
	# 2: tagattrname	in tag attrname		'<kikoo '
	# 3: tagattreql		before tag =		'<kikoo lol'
	# 4: tagattval		before tag attrval	'<kikoo lol='
	# 5: tagattrvalraw	in tag attrval		'<kikoo lol=huu'
	# 6: tagattrvaldquot	in tag with "		'<kikoo lol="hoho'
	# 7: tagattrvalsquot	in tag with '		'<kikoo lol=\'haha'
	# 8: comment		in comment		'<!-- '
	# 9: tagend		wait for end of tag	'<kikoo /'
	# 10: script		in script/style tag	'<script '
	
	# stream:  blabla<tag t=tv tg = "tav" tag='t'><kikoo/>
	# state:  00000001111224552223446666522224775011111190
	
	# tags type and attrname downcased
	
	pg = page.gsub(/\s+/, ' ')	# incl. newlines
	pg.length.times { |pos|
		c = pg[pos] # any other way to enumerate characters of the string portably (ruby 1.8 & 1.9) ?

		case state
		when :waitopen # string
			case c
			when ?<
				if curword.length > 0
					curelem = HtmlElement.new_string(curword.strip)
					if parse
						parse << curelem
					else
						yield curelem
					end
				end
				curword = ''
				curelem = HtmlElement.new
				state = :waittagtype
			when ?\ 	# space
				curword << c if curword.length > 0
			else
				curword << c
			end
		when :waittagtype
			case c
			when ?\ 	# space
				next
			end
			state = :tagtype
			redo
		when :tagtype # after tag start
			case curword.downcase
			when '!--' # html comment
				curword = c.chr
				state = :comment
				next
			when '![cdata[' # xml cdata
				curword = c.chr
				state = :cdata
				next
			end
			
			case c
			when ?>
				curelem.type = curword.downcase
				case curelem.type
				when 'script', 'style'
					curword = curelem.to_s
					state = :script
					next
				end
				if parse
					parse << curelem
				else
					yield curelem
				end
				curword = ''
				state = :waitopen
			when ?/
				if curword.length == 0
					# / at the beginning of a tag
					curword = c.chr
				else
					laststate = state
					state = :tagend
				end
			when ?\ 	# space
				if curword.length > 0
					# <    kikoospaces lol="mdr">
					curelem.type = curword.downcase
					curword = ''
					state = :tagattrname
				end
			else
				curword << c
			end
		when :tagattrname # tagattrname
			case c
			when ?>
				curelem[curword.downcase] = '' if curword.length > 0
				case curelem.type
				when 'script', 'style'
					curword = curelem.to_s
					state = :script
					next
				end
			
				if parse
					parse << curelem
				else
					yield curelem
				end
				curword = ''
				state = :waitopen
			when ?/
				laststate = state
				state = :tagend
			when ?\ 	# space
				curattrname = curword.downcase
				curword = ''
				state = :tagattreql
			when ?=
				curattrname = curword.downcase
				curword = ''
				state = :tagattrval
			else
				curword << c
			end
		when :tagattreql # aftertagattrname
			case c
			when ?>
				curelem[curattrname] = ''
				case curelem.type	
				when 'script', 'style'
					curword = curelem.to_s
					state = :script
					next
				end
				if parse
					parse << curelem
				else
					yield curelem
				end
				state = :waitopen
			when ?/
				laststate = state
				state = :tagend
			when ?=
				state = :tagattrval
			else
				curelem[curattrname] = ''
				curword << c
				state = :tagattrname
			end
		when :tagattrval # beforetagattrval
			case c
			when ?>
				curelem[curattrname] = ''
				case curelem.type
				when 'script', 'style'
					curword = curelem.to_s
					state = :script
					next
				end
				if parse
					parse << curelem
				else
					yield curelem
				end
				state = :waitopen
			when ?/
				laststate = state
				state = :tagend
			when ?"
				state = :tagattrvaldquot
			when ?'
				state = :tagattrvalsquot
			when ?\ 	# space
				# nop
			else
				curword << c
				state = :tagattrvalraw
			end
		when :tagattrvalraw # attrval
			case c
			when ?>
				curelem[curattrname] = curword
				case curelem.type
				when 'script', 'style'
					curword = curelem.to_s
					state = :script
					next
				end
				if parse
					parse << curelem
				else
					yield curelem
				end
				curword = ''
				state = :waitopen
			when ?/
				laststate = state
				state = :tagend
			when ?\ 	# space
				curelem[curattrname] = curword
				curword = ''
				state = :tagattrname
			else
				curword << c
			end
		when :tagattrvaldquot # attrval, doublequote
			case c
			when ?"
				state = :tagattrvalraw
			else
				curword << c
			end
		when :tagattrvalsquot # attrval, singlequote
			case c
			when ?'
				state = :tagattrvalraw
			else
				curword << c
			end
		when :comment, :cdata # comment
			case c
			when ?>
				if (state == :comment and curword[-1] == ?- and curword[-2] == ?-) or (state == :cdata and curword[-1] == ?] and curword[-2] == ?])
					curelem.type = state.to_s.capitalize
					curelem['content'] = curword[0...-2]
					if parse
						parse << curelem
					else
						yield curelem
					end
					curword = ''
					state = :waitopen
				else
					curword << c
				end
			else
				curword << c
			end
		when :tagend # wait for end of tag
			if (c != ?>)
				curword << ?/
			else
				curelem.empty = true
			end
			state = laststate
			redo
		when :script # <script
			if (c == ?> and curword =~ /<\s*\/\s*#{curelem.type}\s*$/i)
				curelem.type.capitalize!
				curelem['content'] = curword << c
				curelem.empty = true
				if parse
					parse << curelem
				else
					yield curelem
				end
				curword = ''
				state = :waitopen
			else
				curword << c
			end
		end
	}
	if state == :waitopen and curword.length > 0
		curelem = HtmlElement.new_string(curword.strip)
		if parse
			parse << curelem
		else
			yield curelem
		end
	end

	parse.done if parse.respond_to? :done
	return parse
end
